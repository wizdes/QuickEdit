#!/bin/bash
# QuickEdit's one entry point (Doc B section 4).
#   ./build.sh                        Release build to build/Release/QuickEdit.app, signed
#   ./build.sh test                   Debug build + unit and UI tests
#   ./build.sh unit                   unit tests only (works with the screen locked)
#   ./build.sh only <T[/C[/m]]>...    just these tests, same checks (for reruns)
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
ui_tests_possible() {
    # IOConsoleLocked can say No while the screen is locked; this key is reliable.
    if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
        echo "UI TESTS: NOT RUN. The screen is locked; unlock it and run again." >&2
        return 1
    fi
    local status
    status="$(perl -e 'alarm 20; exec @ARGV' automationmodetool </dev/null 2>&1 || true)"
    if grep -q 'Automation Mode is disabled' <<<"$status" && grep -q 'requires user authentication' <<<"$status"; then
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
    rm -rf "$dir"
    mkdir -p "$dir"
    local name
    for name in open-type-save new-save boundary ext-on ext-off ext-md open-panel shots; do
        mkdir -p "$dir/$name"
    done
    printf 'abc\n' >"$dir/open-type-save/hello.txt"
    printf 'start\n' >"$dir/boundary/boundary.txt"
    printf 'opened by the Open panel\n' >"$dir/open-panel/openme.txt"
}

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
    local args=(-project "$PROJECT" -scheme QuickEdit -configuration Debug -derivedDataPath "$DERIVED"
        -resultBundlePath "$results" -destination 'platform=macOS,arch=arm64'
        CODE_SIGN_IDENTITY=- CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
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
    # Stop any test host or UI-test app copy the run left behind.
    pkill -f "$DERIVED/Build/Products/Debug/QuickEdit.app/Contents/MacOS/QuickEdit" 2>/dev/null || true
    pkill -f "$DERIVED/Build/Products/Debug/QuickEditUITests-Runner.app/Contents/MacOS/QuickEditUITests-Runner" 2>/dev/null || true
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

cmd="${1:-release}"
case "$cmd" in
    release|"")
        release_build
        ;;
    test)
        if ui_tests_possible; then
            run_tests "" all
        else
            run_tests "QuickEditTests" unit
            die "UI tests not run (reason above), so ./build.sh test cannot pass"
        fi
        ;;
    unit)
        run_tests "QuickEditTests" unit
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
            echo "WARNING: --skip-tests given; packaging WITHOUT running the tests (root use only)" >&2
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
        die "unknown command '$cmd' (use: release, test, unit, dist M<n>)"
        ;;
esac
