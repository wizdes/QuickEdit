#!/bin/bash
# Checks scripts/make-dmg.sh (M10 n3) with signing and notarizing faked:
# fake xcrun (notarytool, stapler), codesign and spctl on PATH record their
# calls. hdiutil is real, so the DMG layout is the real one.
#   bench/tests/make-dmg-test.sh
# Never signs, notarizes or touches builds/.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d -t qe-make-dmg-test)"
cleanup() {
    # A failing case may leave a DMG mounted under $WORK; never leave one.
    hdiutil info | awk -v w="$WORK" 'index($0, w) { print $NF }' | while read -r mp; do
        hdiutil detach -force "$mp" >/dev/null 2>&1
    done
    rm -rf "$WORK"
}
trap cleanup EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# A small stand-in QuickEdit.app: the script only needs the executable.
APP="$WORK/in/QuickEdit.app"
mkdir -p "$APP/Contents/MacOS"
cp /usr/bin/true "$APP/Contents/MacOS/QuickEdit"

# Fakes. CALLS gets one line per call. QE_FAKE_DMG_STATUS sets the notary
# status for the DMG; QE_FAKE_VERIFY_FAIL=1 fails the mounted app's
# codesign --verify --deep (the check inside the mounted DMG).
BIN="$WORK/bin"
mkdir -p "$BIN"
cat >"$BIN/xcrun" <<'FAKE'
#!/bin/bash
echo "xcrun $*" >>"$CALLS"
case "$1 $2" in
    "notarytool history") echo '[]' ;;
    "notarytool submit")
        status=Accepted
        [[ "$3" == *.dmg ]] && status="${QE_FAKE_DMG_STATUS:-Accepted}"
        printf '{"id":"fake-%s","status":"%s"}\n' "$(basename "$3")" "$status" ;;
    "notarytool log") echo '{"issues":["fake"]}' ;;
    "stapler staple"|"stapler validate") ;;
    *) echo "fake xcrun: unexpected: $*" >&2; exit 2 ;;
esac
FAKE
cat >"$BIN/codesign" <<'FAKE'
#!/bin/bash
echo "codesign $*" >>"$CALLS"
if [ "${QE_FAKE_VERIFY_FAIL:-0}" = 1 ] && [[ " $* " == *" --deep "* ]]; then
    echo "fake codesign: invalid signature" >&2; exit 1
fi
exit 0
FAKE
printf '#!/bin/bash\necho "spctl $*" >>"$CALLS"\n' >"$BIN/spctl"
chmod +x "$BIN"/*

run() { # run OUT_DIR [args...]: runs make-dmg.sh, sets out and status
    local outdir="$1"; shift
    mkdir -p "$outdir"
    : >"$WORK/calls"
    out="$(CALLS="$WORK/calls" PATH="$BIN:$PATH" QE_DEVID="Fake ID" NOTARY_PROFILE=fake-profile \
        "$ROOT/scripts/make-dmg.sh" "$APP" "$outdir/QuickEdit-T.dmg" "$@" 2>&1)"
    status=$?
}
mounted_under() { hdiutil info | grep -qF "$1"; }

# 1. The full path: app notarized and stapled first, then the DMG made,
#    signed, notarized and stapled, in that order; the DMG holds the app and
#    an Applications link; no zip and no work folder are left; nothing mounted.
run "$WORK/out1"
if [ "$status" -eq 0 ] && [ -s "$WORK/out1/QuickEdit-T.dmg" ]; then
    pass "make-dmg.sh makes the DMG"
else
    fail "make-dmg.sh failed (exit $status): $(tail -3 <<<"$out")"
fi
expected="notarytool submit $WORK/out1/.make-dmg-work/notary/QuickEdit.zip
stapler staple $APP
codesign --force $WORK/out1/QuickEdit-T.dmg
notarytool submit $WORK/out1/QuickEdit-T.dmg
stapler staple $WORK/out1/QuickEdit-T.dmg"
# Each call reduced to its tool, its action and the file it acts on.
reduce_calls() {
    local line art
    grep -E 'notarytool submit|stapler staple|codesign --force' "$WORK/calls" | while read -r line; do
        case "$line" in
            *"notarytool submit"*) art="${line#xcrun notarytool submit }"; echo "notarytool submit ${art%% --keychain-profile*}" ;;
            *"stapler staple"*) echo "stapler staple ${line#xcrun stapler staple }" ;;
            codesign*) echo "codesign --force ${line##* }" ;;
        esac
    done
}
order="$(reduce_calls)"
if [ "$order" = "$expected" ]; then
    pass "notarize and staple the app, then sign, notarize and staple the DMG, in that order"
else
    fail "call order was:
$order"
fi
grep -q "spctl --assess --type open --context context:primary-signature -vv $WORK/out1/QuickEdit-T.dmg" "$WORK/calls" \
    && pass "Gatekeeper check on the stapled DMG" || fail "no spctl check of the DMG"
mkdir -p "$WORK/mnt1"
if hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$WORK/mnt1" "$WORK/out1/QuickEdit-T.dmg"; then
    contents="$(ls -A "$WORK/mnt1" | grep -v '^\.' | tr '\n' ' ')"
    if [ -x "$WORK/mnt1/QuickEdit.app/Contents/MacOS/QuickEdit" ] && [ -L "$WORK/mnt1/Applications" ] \
        && [ "$(readlink "$WORK/mnt1/Applications")" = /Applications ] && [ "$contents" = "Applications QuickEdit.app " ]; then
        pass "the DMG holds QuickEdit.app and an Applications link, nothing else"
    else
        fail "DMG contents: $contents"
    fi
    hdiutil detach -quiet "$WORK/mnt1" || fail "could not detach the test mount"
else
    fail "could not mount the DMG"
fi
hdiutil imageinfo "$WORK/out1/QuickEdit-T.dmg" 2>/dev/null | grep -q "Format: UDZO" && pass "the DMG is UDZO" || fail "the DMG is not UDZO"
[ -z "$(find "$WORK/out1" -name '*.zip')" ] && [ ! -e "$WORK/out1/.make-dmg-work" ] \
    && pass "no zip and no work folder left" || fail "left over: $(find "$WORK/out1" | tr '\n' ' ')"
mounted_under "$WORK/out1" && fail "a DMG is still mounted" || pass "nothing left mounted"

# 2. --no-notarize (keychain locked): a DMG with the same layout, and no
#    notarizing, stapling or signing at all.
run "$WORK/out2" --no-notarize
if [ "$status" -eq 0 ] && [ -s "$WORK/out2/QuickEdit-T.dmg" ] \
    && ! grep -qE 'notarytool|stapler|codesign --force|spctl' "$WORK/calls"; then
    pass "--no-notarize makes an unsigned DMG and never notarizes"
else
    fail "--no-notarize (exit $status): $(tr '\n' ';' <"$WORK/calls") $(tail -2 <<<"$out")"
fi

# 3. A DMG the notary service rejects stops the run with its status and log.
QE_FAKE_DMG_STATUS=Invalid run "$WORK/out3"
if [ "$status" -ne 0 ] && grep -q "notary status: Invalid" <<<"$out" && grep -q "notarytool log fake-QuickEdit-T.dmg" "$WORK/calls"; then
    pass "a rejected DMG fails with the notary status and fetches the log"
else
    fail "rejected DMG (exit $status): $(tail -3 <<<"$out")"
fi

# 4. A bad app inside the mounted DMG fails the run, and the DMG is detached.
QE_FAKE_VERIFY_FAIL=1 run "$WORK/out4"
if [ "$status" -ne 0 ] && grep -q "DMG contents failed verification" <<<"$out" && ! mounted_under "$WORK/out4"; then
    pass "a bad app in the DMG fails the run and the DMG is detached"
else
    fail "bad mounted app (exit $status, mounted: $(mounted_under "$WORK/out4" && echo yes || echo no)): $(tail -3 <<<"$out")"
fi

# 5. A zip next to the DMG (an old zip release of the same name) fails the run.
mkdir -p "$WORK/out5"; echo old >"$WORK/out5/QuickEdit-T.zip"
run "$WORK/out5" --no-notarize
if [ "$status" -ne 0 ] && grep -q "a zip is left next to the DMG" <<<"$out"; then
    pass "a leftover zip fails the run"
else
    fail "leftover zip (exit $status): $(tail -2 <<<"$out")"
fi

# 6. Bad input: no app, or an output that is not a .dmg.
out="$(PATH="$BIN:$PATH" "$ROOT/scripts/make-dmg.sh" "$WORK/nothing.app" "$WORK/x.dmg" 2>&1)"; s1=$?
out2="$(PATH="$BIN:$PATH" "$ROOT/scripts/make-dmg.sh" "$APP" "$WORK/x.zip" 2>&1)"; s2=$?
if [ "$s1" -ne 0 ] && grep -q "not a QuickEdit app" <<<"$out" && [ "$s2" -ne 0 ] && grep -q "must end in .dmg" <<<"$out2"; then
    pass "bad input is refused"
else
    fail "bad input: $s1 $out / $s2 $out2"
fi

if [ "$fails" -gt 0 ]; then echo "make-dmg-test: $fails FAILED"; exit 1; fi
echo "make-dmg-test: all passed"
