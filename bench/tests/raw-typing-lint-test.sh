#!/bin/bash
# Fails on any raw typeText or typeKey call in QuickEditUITests outside
# QuickEditUITests/SafeTyping.swift.
#   bench/tests/raw-typing-lint-test.sh
# XCUITest sends keys to whatever app is in front; a raw call can type into
# another app (a Return in a terminal runs a command). SafeTyping.swift's
# safeType and safePress check that QuickEdit is in front before each key.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d -t qe-raw-typing-lint)"
trap 'rm -rf "$WORK"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# Prints file:line:text for each raw call under $1, except in SafeTyping.swift.
raw_calls() {
    grep -rnE --include='*.swift' '\btype(Text|Key)[[:space:]]*\(' "$1" | grep -v '/SafeTyping\.swift:' || true
}

# 1. The check itself catches a raw call (on app, on an element) and lets
#    the helper file and the guarded calls through.
mkdir -p "$WORK/sample"
printf '        app.typeText("x")\n        field.typeKey("a", modifierFlags: .command)\n        safeType("x")\n' \
    >"$WORK/sample/Sample.swift"
printf '        (target ?? app).typeText(String(chunk))\n' >"$WORK/sample/SafeTyping.swift"
found="$(raw_calls "$WORK/sample")"
if [ "$(grep -c . <<<"$found")" -eq 2 ] && grep -q 'Sample.swift:1:' <<<"$found" \
    && grep -q 'Sample.swift:2:' <<<"$found"; then
    pass "the check finds raw calls and skips SafeTyping.swift and safeType"
else
    fail "the check misread the sample: ${found:-nothing found}"
fi

# 2. QuickEditUITests has no raw call.
found="$(raw_calls "$ROOT/QuickEditUITests")"
if [ -z "$found" ]; then
    pass "no raw typeText or typeKey call in QuickEditUITests"
else
    fail "raw typeText or typeKey calls; use safeType or safePress (QuickEditUITests/SafeTyping.swift):"
    echo "$found"
fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "ALL PASS"
