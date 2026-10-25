#!/bin/bash
# QuickEdit's one entry point (Doc B section 4).
#   ./build.sh                        Release build to build/Release/QuickEdit.app, signed
#   ./build.sh test                   shell tests (bench/tests/*.sh), Debug build + unit and UI tests
#   ./build.sh unit                   shell tests, then unit tests only (works with the screen locked)
#   ./build.sh only <T[/C[/m]]>...    just these tests, same checks (for reruns)
#   ./build.sh speed                  the speed tests in an optimized build with their real
#                                     limits (Select Line 200 ms both ways, Wrap to Page 300 ms,
#                                     no main-thread block over 100 ms after it or during a 10 MB
#                                     PDF export, export memory under 2x the text (Wrap to Page: pages laid out first), line-ending
#                                     count of 100 MB 100 ms, Wrap to Page typing p95 8 ms)
#   ./build.sh dist M<n> [--skip-tests]
#                                     full tests, then Release build, zip to builds/QuickEdit-M<n>.zip,
#                                     notarize when the keychain is open
# Every command prints its result and exits non-zero on failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
DERIVED="$BUILD/DerivedData"
PROJECT="$ROOT/QuickEdit.xcodeproj"
APP="$BUILD/Release/QuickEdit.app"
ENTITLEMENTS="$ROOT/QuickEdit/Resources/QuickEdit.entitlements"
DEVID="Developer ID Application: Yi Li (8Q5V8XK85Y)"
NOTARY_PROFILE="fastpad-notary"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

die() { echo "FAILED: $*" >&2; exit 1; }

generate() {
    xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" --quiet \
        || die "xcodegen generate"
    echo "xcodegen: Created project $PROJECT"
}

# True when Developer ID signing works right now. A locked login keychain
# makes codesign fail with errSecInternalComponent, so try it on a scratch file.
keychain_open() {
    local probe
    probe="$(mktemp -t qe-sign-probe)"
    cp /usr/bin/true "$probe"
    if perl -e 'alarm 30; exec @ARGV' codesign --force --sign "$DEVID" "$probe" </dev/null >/dev/null 2>&1; then
        rm -f "$probe"; return 0
    fi
    rm -f "$probe"; return 1
}

release_build() {
    generate
    local log="$BUILD/release-build.log"
    mkdir -p "$BUILD"
    echo "xcodebuild: Release (log: $log)"
    if ! xcodebuild -project "$PROJECT" -scheme QuickEdit -configuration Release \
        -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY=- CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        build >"$log" 2>&1; then
        grep -E ': error: |BUILD FAILED' "$log" | head -20 >&2
        die "Release build (log: $log)"
    fi
    rm -rf "$APP"
    mkdir -p "$BUILD/Release"
    ditto "$DERIVED/Build/Products/Release/QuickEdit.app" "$APP"
    [ -x "$APP/Contents/MacOS/QuickEdit" ] || die "$APP/Contents/MacOS/QuickEdit missing"

    if keychain_open; then
        codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$APP" \
            || die "Developer ID signing"
        echo "SIGNING: $DEVID"
        SIGNED_DEVID=1
    else
        codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP" \
            || die "ad-hoc signing"
        echo "SIGNING: ad-hoc (keychain locked)"
        SIGNED_DEVID=0
    fi
    codesign --verify --strict "$APP" || die "codesign --verify"
    echo "built: $APP (version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist") build $BUILD_NUMBER)"
}

# XCUITest must turn on macOS Automation Mode. When the Mac needs a password
# for that and nobody types it, the runner times out AND leaves testmanagerd
# stuck, so every later test run hangs. Check first instead.
# True when the login screen is locked. IOConsoleLocked can say No while the
# screen is locked; CGSSessionScreenIsLocked is reliable. The ioreg output is
# read into a variable first: in a pipeline, `grep -q` quits at its first
# match, an earlier stage can then die of SIGPIPE, and pipefail turns a
# locked screen into "not locked".
# The match is done in bash itself (no here-string, so no temp file).
screen_locked() {
    local reg
    reg="$(ioreg -n Root -d1 -a)" || die "ioreg failed; cannot tell whether the screen is locked (UI tests NOT possible)"
    [[ "$reg" =~ CGSSessionScreenIsLocked\</key\>[[:space:]]*\<true/\> ]]
}

ui_tests_possible() {
    if screen_locked; then
        echo "UI TESTS: NOT RUN. The screen is locked; unlock it and run again." >&2
        return 1
    fi
    # Any error in this check means NOT possible (M6 review row 11): the
    # tool must run, exit 0 and say something.
    local status amt=0
    status="$(perl -e 'alarm 20; exec @ARGV' automationmodetool </dev/null 2>&1)" || amt=$?
    if [ "$amt" -ne 0 ] || [ -z "$status" ]; then
        echo "UI TESTS: NOT RUN. automationmodetool failed (exit $amt); cannot tell whether Automation Mode can turn on." >&2
        [ -z "$status" ] || echo "  $status" >&2
        return 1
    fi
    if [[ "$status" == *"Automation Mode is disabled"* && "$status" == *"requires user authentication"* ]]; then
        echo "UI TESTS: NOT RUN. Automation Mode is off and needs a password to turn on." >&2
        echo "  To allow UI tests on this Mac, run once in a terminal:" >&2
        echo "  sudo automationmodetool enable-automationmode-without-authentication" >&2
        return 1
    fi
    return 0
}

# Files and folders the UI tests read and save into (see QuickEditUITests/UITestSupport.swift).
make_fixtures() {
    local dir="$1"
    unlock_fixtures "$dir"
    rm -rf "$dir"
    mkdir -p "$dir"
    local name
    for name in open-type-save new-save boundary ext-on ext-off ext-md open-panel shots \
        transient external-clean external-edited locked close-named close-untitled \
        rename-move rename-move/dest restore recent cascade revert encodings dark-mode; do
        mkdir -p "$dir/$name"
    done
    printf 'abc\n' >"$dir/open-type-save/hello.txt"
    printf 'start\n' >"$dir/boundary/boundary.txt"
    printf 'opened by the Open panel\n' >"$dir/open-panel/openme.txt"
    # M2 document life (QuickEditUITests/DocumentLifeTests.swift and friends).
    printf 'replaces the untitled window\n' >"$dir/transient/replace.txt"
    printf 'before\n' >"$dir/external-clean/outside.txt"
    printf 'before\n' >"$dir/external-edited/outside.txt"
    printf 'locked text\n' >"$dir/locked/locked.txt"
    chflags uchg "$dir/locked/locked.txt"
    printf 'named\n' >"$dir/close-named/named.txt"
    printf 'move me\n' >"$dir/rename-move/original.txt"
    printf 'recent\n' >"$dir/recent/recent.txt"
    printf 'saved text\n' >"$dir/revert/revert.txt"
    # M3 encodings (QuickEditUITests/EncodingPanelTests.swift).
    printf 'caf\303\251\n' >"$dir/encodings/utf8.txt"
    printf 'caf\351\n' >"$dir/encodings/latin.txt"
    xattr -w com.apple.TextEncoding 'windows-1252;1280' "$dir/encodings/latin.txt"
    printf 'one\r\ntwo\r\n' >"$dir/encodings/crlf.txt"
    # M3+M5 review row 9 (QuickEditUITests/M35ReviewUITests.swift).
    printf 'abc\n' >"$dir/encodings/cancel.txt"
    # The dark mode test opens this instead of typing 540 characters
    # (QuickEditUITests/LayoutTests.swift, testDarkModeKeepsTextReadable).
    awk 'BEGIN { for (i = 0; i < 20; i++) printf "readable text in dark mode\n" }' >"$dir/dark-mode/dark.txt"
    # About 1 MB of numbered lines; the restoration test selects line 13000.
    awk 'BEGIN { for (i = 0; i < 26000; i++) printf "line %d of the restoration fixture\n", i }' \
        >"$dir/restore/restore-1mb.txt"
}

# Locked fixtures (chflags uchg) cannot be deleted; unlock them after a run.
unlock_fixtures() {
    chflags -R nouchg "$1" 2>/dev/null || true
}

# Where run_tests builds, extra build settings, and its last log. `speed`
# changes the first two.
TEST_DERIVED="$DERIVED"
TEST_SETTINGS=()
TEST_LOG=""

# Runs xcodebuild test and checks the result bundle: zero tests, any skipped
# test, any failure, or any retried test is a failure.
run_tests() {
    local only="$1" label="$2"
    generate
    local stamp results log
    stamp="$(date +%Y%m%d-%H%M%S)"
    results="$BUILD/test-results/$label-$stamp.xcresult"
    log="$BUILD/test-results/$label-$stamp.log"
    mkdir -p "$BUILD/test-results"
    TEST_LOG="$log"
    local args=(-project "$PROJECT" -scheme QuickEdit -configuration Debug -derivedDataPath "$TEST_DERIVED"
        -resultBundlePath "$results" -destination 'platform=macOS,arch=arm64'
        CODE_SIGN_IDENTITY=- CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ${TEST_SETTINGS[@]+"${TEST_SETTINGS[@]}"}
        )
    if [ -n "$only" ]; then
        for target in $only; do args+=("-only-testing:$target"); done
    fi
    # The UI test runner is sandboxed: it can read any path but write only
    # inside its own container. So the fixture files are made here, and the
    # (unsandboxed) app saves into these folders.
    local fixtures="$BUILD/uitest-fixtures/$label-$stamp"
    make_fixtures "$fixtures"
    export TEST_RUNNER_QE_FIXTURES="$fixtures"
    echo "xcodebuild test: $label (log: $log)"
    echo "fixtures: $fixtures"
    echo "results: $results"
    local status=0
    # A hung test host must not hang the build: xcodebuild gets a hard limit.
    perl -e 'alarm shift; exec @ARGV' "${QE_TEST_TIMEOUT:-1200}" xcodebuild test "${args[@]}" \
        </dev/null >"$log" 2>&1 || status=$?
    if [ "$status" -eq 142 ]; then
        echo "xcodebuild test hit the ${QE_TEST_TIMEOUT:-1200} s limit and was stopped" >&2
    fi
    unlock_fixtures "$fixtures"
    # Stop any test host or UI-test app copy the run left behind.
    pkill -f "$TEST_DERIVED/Build/Products/Debug/QuickEdit.app/Contents/MacOS/QuickEdit" 2>/dev/null || true
    pkill -f "$TEST_DERIVED/Build/Products/Debug/QuickEditUITests-Runner.app/Contents/MacOS/QuickEditUITests-Runner" 2>/dev/null || true
    grep -E "^Test Case .*(failed|skipped)|: error: " "$log" | head -30 >&2 || true

    [ -d "$results" ] || die "no result bundle at $results (xcodebuild exit $status)"
    local summary
    summary="$(xcrun xcresulttool get test-results summary --path "$results" --compact)" \
        || die "xcresulttool could not read $results"
    local counts
    counts="$(python3 -I -c '
import json, sys
s = json.loads(sys.stdin.read())
print(s.get("totalTestCount", 0), s.get("passedTests", 0), s.get("failedTests", 0),
      s.get("skippedTests", 0), s.get("expectedFailures", 0), s.get("result", "?"))
' <<<"$summary")"
    read -r total passed failed skipped expected result <<<"$counts"
    if [ "$failed" != "0" ] || [ "$skipped" != "0" ]; then
        xcrun xcresulttool get test-results tests --path "$results" --compact | python3 -I -c '
import json, sys
def walk(node, path):
    name = node.get("name", "")
    kind = node.get("nodeType", "")
    if kind == "Test Case" and node.get("result") in ("Failed", "Skipped"):
        print("  " + node.get("result").upper() + ": " + path + name)
        for child in node.get("children", []):
            if child.get("nodeType") in ("Failure Message", "Skip Message"):
                print("      " + child.get("name", ""))
    for child in node.get("children", []):
        walk(child, path + (name + "/" if kind == "Test Suite" else ""))
for n in json.load(sys.stdin).get("testNodes", []):
    walk(n, "")
' >&2 || true
    fi
    local retried
    retried="$(grep -cE "Restarting after unexpected exit|Retrying test|Test Case .* retried" "$log" || true)"
    echo "TESTS ($label): executed=$total passed=$passed failed=$failed skipped=$skipped expected_failures=$expected result=$result"
    [ "$status" -eq 0 ] || die "xcodebuild test exited $status"
    [ "$total" -gt 0 ] || die "zero tests executed"
    [ "$failed" -eq 0 ] || die "$failed test(s) failed"
    [ "$skipped" -eq 0 ] || die "$skipped test(s) skipped"
    [ "$expected" -eq 0 ] || die "$expected expected failure(s)"
    [ "$passed" -eq "$total" ] || die "passed $passed of $total"
    [ "$retried" -eq 0 ] || die "a test was retried ($retried log lines)"
    echo "TESTS ($label): PASS $passed of $total"
}

# Runs every bench/tests/*.sh (M2 review row 7) before any Xcode work; any
# failure stops the command. QE_SHELL_TESTS_DIR overrides the folder (used by
# bench/tests/build-sh-test.sh to check this function).
run_shell_tests() {
    local dir="${QE_SHELL_TESTS_DIR:-$ROOT/bench/tests}" script name status
    local ran=0 failed=()
    for script in "$dir"/*.sh; do
        [ -e "$script" ] || continue
        name="$(basename "$script")"
        echo "shell test: $name"
        status=0
        perl -e 'alarm 900; exec @ARGV' "$script" </dev/null >"$BUILD/shell-test-$name.log" 2>&1 || status=$?
        ran=$((ran + 1))
        if [ "$status" -ne 0 ]; then
            failed+=("$name")
            tail -5 "$BUILD/shell-test-$name.log" >&2
            echo "  (exit $status, log: $BUILD/shell-test-$name.log)" >&2
        fi
    done
    [ "$ran" -gt 0 ] || die "no shell tests found in $dir"
    if [ "${#failed[@]}" -gt 0 ]; then
        echo "SHELL TESTS: FAILED: ${failed[*]}" >&2
        die "${#failed[@]} of $ran shell test(s) failed"
    fi
    echo "SHELL TESTS: PASS $ran of $ran"
}

cmd="${1:-release}"
case "$cmd" in
    release|"")
        release_build
        ;;
    test)
        mkdir -p "$BUILD"
        run_shell_tests
        if ui_tests_possible; then
            run_tests "" all
        else
            run_tests "QuickEditTests" unit
            die "UI tests not run (reason above), so ./build.sh test cannot pass"
        fi
        ;;
    unit)
        mkdir -p "$BUILD"
        run_shell_tests
        run_tests "QuickEditTests" unit
        ;;
    speed)
        # M3+M5 review row 7 (M4 row 6). The same speed tests the unit run
        # has, built optimized: they then hold their real limits (the -Onone
        # unit run only checks loose bounds). Debug with -O, so @testable
        # import still works; its own derived data, removed afterwards.
        mkdir -p "$BUILD"
        TEST_DERIVED="$BUILD/DerivedData-speed-$$"
        trap 'rm -rf "$TEST_DERIVED"' EXIT
        TEST_SETTINGS=(SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule ENABLE_HARDENED_RUNTIME=NO)
        run_tests "QuickEditTests/LinePanelTests/testSelectLineOneMillionIn100MB QuickEditTests/LinePanelTests/testSelectLineBackNearlyOneMillionIn100MB QuickEditTests/PageModeTests/testTenMegabyteSwitchTime QuickEditTests/WrapToPageStallTests/testTenMegabyteNoStallAfterSwitch QuickEditTests/PrintTests/testTenMegabyteExportKeepsTheWindowResponsive QuickEditTests/PrintTests/testTenMegabyteExportInWrapToPageKeepsTheWindowResponsive QuickEditTests/PrintTests/testTenMegabyteExportInWrapToPageStaysUnderTwiceTheText QuickEditTests/PlainTextIOTests/testLineEndingCountOf100MBIsFast QuickEditTests/TypingSpeedTests/testWrapToPageTypingAtTheStartOf100MB" speed
        echo "SPEED (medians, limits in brackets):"
        grep -E "^Select Line 1,000,000 in 100 MB" "$TEST_LOG" | head -1 | sed -E 's/.*(median [0-9.]+ ms).*/  Select Line forward, 1,000,000 lines of 100 MB: \1 [200 ms]/'
        grep -E "^Select Line -999999 from the end" "$TEST_LOG" | head -1 | sed -E 's/.*(median [0-9.]+ ms).*/  Select Line backward, -999999 from the end: \1 [200 ms]/'
        grep -E "^M5-TIMING" "$TEST_LOG" | head -1 | sed -E 's/.*switch to page ms: [^;]* median ([0-9.]+);.*/  Wrap to Page switch, 10 MB: median \1 ms [300 ms]/'
        grep -E "^M8-N3" "$TEST_LOG" | head -1 | sed -E 's/.*(longest main-thread gap [0-9.]+ ms).*/  Wrap to Page, 3 s after the 10 MB switch: \1 [100 ms]/'
        grep -E "^M8-N6 10 MB Wrap to Window export" "$TEST_LOG" | head -1 | sed -E 's/.*(longest main-thread gap [0-9.]+ ms); (peak footprint [^ ]+ MB) \(text ([0-9]+) MB.*/  10 MB export, Wrap to Window: \1 [100 ms]; \2 [2x the \3 MB text]/'
        grep -E "^M8-N6 10 MB Wrap to Page export: " "$TEST_LOG" | head -1 | sed -E 's/.*(longest main-thread gap [0-9.]+ ms); (peak footprint [^ ]+ MB).*/  10 MB export, Wrap to Page, pages laid out meanwhile: \1 [100 ms]; \2 (no limit: holds the pages too)/'
        grep -E "^M8-N6 10 MB Wrap to Page export after its pages" "$TEST_LOG" | head -1 | sed -E 's/.*(peak footprint [^ ]+ MB) \(text ([0-9]+) MB in memory\); the ([0-9]+) pages themselves ([^ ]+ MB).*/  10 MB export, Wrap to Page, pages laid out first: \1 [2x the \2 MB text]; the \3 pages took \4/'
        grep -E "^M8-N2 line-ending count" "$TEST_LOG" | sed -E 's/^M8-N2 line-ending count, 100 MB of ([A-Z]+) lines: ([0-9.]+ ms).*/  Line-ending count, 100 MB of \1 lines: \2 [100 ms]/'
        grep -E "^slow keys.*M8-N7 100 MB Wrap to Page typing at the start" "$TEST_LOG" | head -1 | sed -E 's/.*total p50 ([0-9.]+) p95 ([0-9.]+) .*/  Wrap to Page typing at the start of 100 MB: p50 \1 ms, p95 \2 ms [p95 8 ms]/'
        # The limits apply only when the tests saw an optimized build.
        [ "$(grep -cE '^Select Line .*optimized \(-O\)' "$TEST_LOG")" -eq 2 ] \
            || die "the Select Line tests did not run optimized (log: $TEST_LOG)"
        grep -qE '^M5-TIMING.*optimized: true' "$TEST_LOG" \
            || die "the Wrap to Page test did not run optimized (log: $TEST_LOG)"
        grep -qE '^M8-N3.*optimized: true' "$TEST_LOG" \
            || die "the Wrap to Page stall test did not run optimized (log: $TEST_LOG)"
        [ "$(grep -cE '^M8-N6 10 MB .* export.*optimized: true' "$TEST_LOG")" -eq 3 ] \
            || die "the three 10 MB export tests did not run optimized (log: $TEST_LOG)"
        [ "$(grep -cE '^M8-N2 line-ending count.*optimized: true' "$TEST_LOG")" -eq 2 ] \
            || die "the line-ending count test did not run optimized (log: $TEST_LOG)"
        grep -qE 'M8-N7 100 MB Wrap to Page typing at the start.*optimized: true' "$TEST_LOG" \
            || die "the Wrap to Page typing test did not run optimized (log: $TEST_LOG)"
        echo "SPEED: PASS"
        ;;
    uicheck)
        # Only the check that ./build.sh test runs before any UI test.
        ui_tests_possible || die "UI tests cannot run (reason above)"
        echo "UI TESTS: possible (screen unlocked, Automation Mode can turn on)"
        ;;
    only)
        shift
        [ "$#" -gt 0 ] || die "usage: ./build.sh only <Target[/Class[/method]]>..."
        if [[ "$*" == *QuickEditUITests* ]]; then ui_tests_possible || die "UI tests not run (reason above)"; fi
        run_tests "$*" only
        ;;
    dist)
        milestone="${2:-}"
        [[ "$milestone" =~ ^M[0-9]+$ ]] || die "usage: ./build.sh dist M<n> [--skip-tests]"
        if [ "${3:-}" = "--skip-tests" ]; then
            SKIP_WARNING="WARNING: --skip-tests given; packaging WITHOUT running the tests (root use only)"
            echo "$SKIP_WARNING" >&2
            # Repeat it as the last line, whether packaging works or fails.
            trap 'echo "$SKIP_WARNING" >&2' EXIT
        else
            ui_tests_possible || die "UI tests cannot run here (reason above); refusing to package"
            run_tests "" all
        fi
        release_build
        mkdir -p "$ROOT/builds"
        zip="$ROOT/builds/QuickEdit-$milestone.zip"
        rm -f "$zip"
        ditto -c -k --keepParent "$APP" "$zip" || die "zip"
        if [ "$SIGNED_DEVID" -eq 1 ]; then
            xcrun notarytool submit "$zip" --wait --keychain-profile "$NOTARY_PROFILE" || die "notarize"
            xcrun stapler staple "$APP" || die "staple"
            rm -f "$zip"
            ditto -c -k --keepParent "$APP" "$zip" || die "zip after staple"
            echo "NOTARIZE: done"
        else
            echo "NOTARIZE: skipped (keychain locked)"
        fi
        echo "dist: $zip ($(stat -f %z "$zip") bytes)"
        ;;
    *)
        die "unknown command '$cmd' (use: release, test, unit, speed, dist M<n>)"
        ;;
esac
