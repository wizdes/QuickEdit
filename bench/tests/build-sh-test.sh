#!/bin/bash
# Checks for build.sh behavior that needs no Xcode run (M1 review row 11).
#   bench/tests/build-sh-test.sh
# Uses fake tools on PATH; never runs UI tests, signs, or notarizes.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d -t qe-build-sh-test)"
trap 'rm -rf "$WORK"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# 1. A locked screen is read as locked even when the ioreg pipeline gets
#    SIGPIPE (grep -q stops reading early and pipefail sees the failure).
mkdir -p "$WORK/locked-bin"
cat >"$WORK/locked-bin/ioreg" <<'FAKE'
#!/bin/bash
# The lock key many times: grep -A1 then writes far more than one pipe
# buffer, and gets SIGPIPE once grep -q has seen the first match and quit.
for i in $(seq 1 20000); do
    printf '\t\t\t<key>CGSSessionScreenIsLocked</key>\n\t\t\t<true/>\n'
done
FAKE
chmod +x "$WORK/locked-bin/ioreg"
out="$(PATH="$WORK/locked-bin:$PATH" "$ROOT/build.sh" uicheck 2>&1)"; status=$?
if [ "$status" -ne 0 ] && grep -q "The screen is locked" <<<"$out"; then
    pass "locked screen with SIGPIPE in the pipeline is reported as locked"
else
    fail "locked screen misread (exit $status): $(tail -2 <<<"$out")"
fi

# 2. dist --skip-tests repeats its warning as the LAST output, even when the
#    packaging fails early (fake xcodegen fails at once).
mkdir -p "$WORK/fail-bin"
printf '#!/bin/bash\necho "fake xcodegen failure" >&2\nexit 1\n' >"$WORK/fail-bin/xcodegen"
chmod +x "$WORK/fail-bin/xcodegen"
out="$(PATH="$WORK/fail-bin:$PATH" "$ROOT/build.sh" dist M99 --skip-tests 2>&1)"; status=$?
last="$(tail -1 <<<"$out")"
if [ "$status" -ne 0 ] && [[ "$last" == WARNING:*skip-tests* ]]; then
    pass "dist --skip-tests ends with its warning"
else
    fail "dist --skip-tests last line is: $last (exit $status)"
fi
[ ! -e "$ROOT/builds/QuickEdit-M99.zip" ] || fail "a zip was made"
[ ! -e "$ROOT/builds/QuickEdit-M99.dmg" ] || fail "a DMG was made"

# 3. `unit` and `test` run the shell tests (M2 review row 7) and fail when one
#    fails, before any Xcode work. QE_SHELL_TESTS_DIR points them at a folder
#    with one failing test; a fake xcodebuild records whether Xcode ran.
mkdir -p "$WORK/shell-fail" "$WORK/xc-bin"
printf '#!/bin/bash\necho "deliberate failure"\nexit 3\n' >"$WORK/shell-fail/always-fails.sh"
chmod +x "$WORK/shell-fail/always-fails.sh"
printf '#!/bin/bash\ntouch "%s/xcodebuild-ran"\nexit 1\n' "$WORK" >"$WORK/xc-bin/xcodebuild"
chmod +x "$WORK/xc-bin/xcodebuild"
for cmd in unit test; do
    rm -f "$WORK/xcodebuild-ran"
    out="$(QE_SHELL_TESTS_DIR="$WORK/shell-fail" PATH="$WORK/xc-bin:$PATH" "$ROOT/build.sh" "$cmd" 2>&1)"; status=$?
    if [ "$status" -ne 0 ] && grep -q "always-fails.sh" <<<"$out" && grep -q "SHELL TESTS: FAILED" <<<"$out" \
        && [ ! -e "$WORK/xcodebuild-ran" ]; then
        pass "./build.sh $cmd runs the shell tests and stops on a failure"
    else
        fail "./build.sh $cmd with a failing shell test (exit $status, xcodebuild ran: $([ -e "$WORK/xcodebuild-ran" ] && echo yes || echo no)): $(tail -2 <<<"$out")"
    fi
done

# 4. `speed` (M3+M5 review row 7) runs the three speed tests in an optimized
#    Debug build with its own derived data, removed afterwards, and fails
#    when xcodebuild fails. Fake xcodegen and xcodebuild record what ran.
mkdir -p "$WORK/speed-bin"
printf '#!/bin/bash\nexit 0\n' >"$WORK/speed-bin/xcodegen"
# The run makes the Debug app's container first when this Mac has none
# (build.sh ensure_debug_container): the fake "build" makes an app whose
# start makes the stand-in container, as macOS does at a first launch.
# The stand-in (QE_TEST_DEBUG_CONTAINER) is used both ways: present, and
# missing (sandbox review B: the speed check failed on a Mac with no
# container, because the fake failed the extra build).
cat >"$WORK/speed-bin/xcodebuild" <<FAKE
#!/bin/bash
if [ "\${@: -1}" = build ]; then
    echo build >>"$WORK/speed-calls"
    prev=""
    for a in "\$@"; do
        if [ "\$prev" = "-derivedDataPath" ]; then
            app="\$a/Build/Products/Debug/QuickEdit.app/Contents/MacOS"
            mkdir -p "\$app"
            printf '#!/bin/bash\nmkdir -p "%s/tmp"\nsleep 5\n' "\$QE_TEST_DEBUG_CONTAINER" >"\$app/QuickEdit"
            chmod +x "\$app/QuickEdit"
        fi
        prev="\$a"
    done
    exit 0
fi
echo test >>"$WORK/speed-calls"
printf '%s\n' "\$@" >"$WORK/speed-args"
printf '%s' "\${TEST_RUNNER_QE_BIG_FILE_TESTS:-}" >"$WORK/speed-big-files"
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-derivedDataPath" ]; then mkdir -p "\$a"; echo "\$a" >"$WORK/speed-derived"; fi
    prev="\$a"
done
exit 1
FAKE
chmod +x "$WORK/speed-bin/xcodegen" "$WORK/speed-bin/xcodebuild"
for container in present missing; do
missing=""
rm -rf "$WORK/container" "$WORK/speed-args" "$WORK/speed-derived" "$WORK/speed-calls" "$WORK/speed-big-files"
[ "$container" = present ] && mkdir -p "$WORK/container/tmp"
out="$(QE_TEST_DEBUG_CONTAINER="$WORK/container" PATH="$WORK/speed-bin:$PATH" "$ROOT/build.sh" speed 2>&1)"; status=$?
calls="$(tr '\n' ' ' <"$WORK/speed-calls" 2>/dev/null)"
want_calls="test "
[ "$container" = missing ] && want_calls="build test "
[ "$calls" = "$want_calls" ] || missing+=" calls '$calls' (want '$want_calls')"
args="$(cat "$WORK/speed-args" 2>/dev/null)"
derived="$(cat "$WORK/speed-derived" 2>/dev/null)"
for want in "-configuration" "Debug" "SWIFT_OPTIMIZATION_LEVEL=-O" "SWIFT_COMPILATION_MODE=wholemodule" \
    "CODE_SIGN_IDENTITY=-" "ENABLE_HARDENED_RUNTIME=NO" \
    "-only-testing:QuickEditTests/LinePanelTests/testSelectLineOneMillionIn100MB" \
    "-only-testing:QuickEditTests/LinePanelTests/testSelectLineBackNearlyOneMillionIn100MB" \
    "-only-testing:QuickEditTests/PageModeTests/testTenMegabyteSwitchTime" \
    "-only-testing:QuickEditTests/WrapToPageStallTests/testTenMegabyteNoStallAfterSwitch" \
    "-only-testing:QuickEditTests/PrintTests/testTenMegabyteExportKeepsTheWindowResponsive" \
    "-only-testing:QuickEditTests/PrintTests/testTenMegabyteExportInWrapToPageKeepsTheWindowResponsive" \
    "-only-testing:QuickEditTests/PrintTests/testTenMegabyteExportInWrapToPageStaysUnderTwiceTheText" \
    "-only-testing:QuickEditTests/PlainTextIOTests/testLineEndingCountOf100MBIsFast" \
    "-only-testing:QuickEditTests/TypingSpeedTests/testWrapToPageTypingAtTheStartOf100MB" \
    "-only-testing:QuickEditTests/LargeFileSpeedTests/testOneGigabyteOpensReadOnlyWithinTheLimits" \
    "-only-testing:QuickEditTests/LargeFileSpeedTests/testHalfGigabyteOpensEditableWithinTheLimits" \
    "-only-testing:QuickEditTests/LargeFileSpeedTests/testOneGigabyteReloadStaysWithinTheLimits"; do
    grep -qxF -- "$want" <<<"$args" || missing+=" $want"
done
# The big-file tests run only with their switch on (M8, vote V3).
[ "$(cat "$WORK/speed-big-files" 2>/dev/null)" = "1" ] || missing+=" TEST_RUNNER_QE_BIG_FILE_TESTS=1"
if [ "$status" -ne 0 ] && [ -z "$missing" ] && [ -n "$derived" ] && [ "$derived" != "$ROOT/build/DerivedData" ] \
    && [ ! -e "$derived" ]; then
    pass "./build.sh speed (container $container) runs the speed tests optimized in its own derived data and removes it"
else
    fail "./build.sh speed, container $container (exit $status, missing args:${missing:-none}, derived: ${derived:-none}, left behind: $([ -n "$derived" ] && [ -e "$derived" ] && echo yes || echo no)): $(tail -2 <<<"$out")"
fi
done

# 5. `uicheck` (M6 review row 11): any error inside the check means NOT
#    possible and a non-zero exit. (a) TMPDIR cannot be written, so bash
#    cannot make temp files (here-strings use them); the screen is locked.
#    (b) automationmodetool fails and prints nothing; the screen is unlocked.
mkdir -p "$WORK/lock-small-bin" "$WORK/amt-fail-bin"
printf '#!/bin/bash\nprintf "\\t<key>CGSSessionScreenIsLocked</key>\\n\\t<true/>\\n"\n' >"$WORK/lock-small-bin/ioreg"
printf '#!/bin/bash\nprintf "\\t<key>CGSSessionOnConsoleKey</key>\\n\\t<true/>\\n"\n' >"$WORK/amt-fail-bin/ioreg"
printf '#!/bin/bash\nexit 1\n' >"$WORK/amt-fail-bin/automationmodetool"
chmod +x "$WORK/lock-small-bin/ioreg" "$WORK/amt-fail-bin/ioreg" "$WORK/amt-fail-bin/automationmodetool"
out="$(TMPDIR="$WORK/no-such-tmp" PATH="$WORK/lock-small-bin:$PATH" "$ROOT/build.sh" uicheck 2>&1)"; status=$?
if [ "$status" -ne 0 ] && grep -q "NOT" <<<"$out"; then
    pass "uicheck with an unwritable TMPDIR reports NOT possible"
else
    fail "uicheck with an unwritable TMPDIR (exit $status): $(tail -2 <<<"$out")"
fi
out="$(PATH="$WORK/amt-fail-bin:$PATH" "$ROOT/build.sh" uicheck 2>&1)"; status=$?
if [ "$status" -ne 0 ] && grep -q "NOT" <<<"$out"; then
    pass "uicheck with a failing automationmodetool reports NOT possible"
else
    fail "uicheck with a failing automationmodetool (exit $status): $(tail -2 <<<"$out")"
fi

echo "build-sh-test: $fails failure(s)"
[ "$fails" -eq 0 ]
