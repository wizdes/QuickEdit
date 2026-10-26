#!/bin/bash
# Fails on any raw typeText or typeKey call in QuickEditUITests outside
# QuickEditUITests/SafeTyping.swift.
#   bench/tests/raw-typing-lint-test.sh
# XCUITest sends keys to whatever app is in front; a raw call can type into
# another app (a Return in a terminal runs a command). SafeTyping.swift's
# safeType and safePress check that QuickEdit is in front before each key.
# The repo is found from this script's real path, so a link to it from
# any folder (./build.sh quick links it into build/quick-shell-tests)
# checks the real QuickEditUITests (M9 review row 10). QE_LINT_UI_DIR
# overrides the folder checked; used only by check 3 below.
set -uo pipefail
real_path() {
    local path="$1" target
    while [ -L "$path" ]; do
        target="$(readlink "$path")"
        case "$target" in
            /*) path="$target" ;;
            *) path="$(dirname "$path")/$target" ;;
        esac
    done
    echo "$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
}
SELF="$(real_path "$0")"
ROOT="$(cd "$(dirname "$SELF")/../.." && pwd -P)"
UI_DIR="${QE_LINT_UI_DIR:-$ROOT/QuickEditUITests}"
if [ ! -d "$UI_DIR" ]; then
    echo "FAIL: the folder to check, $UI_DIR, does not exist"
    exit 1
fi
if [ -z "$(find "$UI_DIR" -name '*.swift' -print -quit)" ]; then
    echo "FAIL: the folder to check, $UI_DIR, has no Swift files"
    exit 1
fi
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
found="$(raw_calls "$UI_DIR")"
if [ -z "$found" ]; then
    pass "no raw typeText or typeKey call in $UI_DIR ($(find "$UI_DIR" -name '*.swift' | wc -l | tr -d ' ') Swift files)"
else
    fail "raw typeText or typeKey calls; use safeType or safePress (QuickEditUITests/SafeTyping.swift):"
    echo "$found"
fi

# 3. Run through a link (as ./build.sh quick does), from a folder at another
#    depth: it still finds and checks the real folder; a missing folder or
#    one with no Swift files fails. Skipped inside its own run.
if [ -z "${QE_LINT_INNER:-}" ]; then
    mkdir -p "$WORK/a/b/c/d" "$WORK/empty"
    ln -s "$SELF" "$WORK/a/b/c/d/lint.sh"
    ln -s "$WORK/a/b/c/d/lint.sh" "$WORK/a/link-to-link.sh"
    out="$(QE_LINT_INNER=1 "$WORK/a/b/c/d/lint.sh" 2>&1)"; status=$?
    if [ "$status" -eq 0 ] && grep -q "in $ROOT/QuickEditUITests (" <<<"$out"; then
        pass "a link at another depth checks $ROOT/QuickEditUITests"
    else
        fail "a link at another depth (exit $status): $out"
    fi
    out="$(QE_LINT_INNER=1 "$WORK/a/link-to-link.sh" 2>&1)"; status=$?
    [ "$status" -eq 0 ] && pass "a link to a link works" || fail "a link to a link (exit $status): $out"
    out="$(QE_LINT_INNER=1 QE_LINT_UI_DIR="$WORK/missing" "$WORK/a/b/c/d/lint.sh" 2>&1)"; status=$?
    [ "$status" -ne 0 ] && grep -q "does not exist" <<<"$out" && pass "a missing folder fails" \
        || fail "a missing folder did not fail (exit $status): $out"
    out="$(QE_LINT_INNER=1 QE_LINT_UI_DIR="$WORK/empty" "$WORK/a/b/c/d/lint.sh" 2>&1)"; status=$?
    [ "$status" -ne 0 ] && grep -q "has no Swift files" <<<"$out" && pass "a folder with no Swift files fails" \
        || fail "a folder with no Swift files did not fail (exit $status): $out"
fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "ALL PASS"
