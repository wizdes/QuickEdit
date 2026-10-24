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

echo "build-sh-test: $fails failure(s)"
[ "$fails" -eq 0 ]
