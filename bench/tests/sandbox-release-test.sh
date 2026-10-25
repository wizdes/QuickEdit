#!/bin/bash
# M9 n1: the Release app's sandbox (docs/plans/M9.md, done-tests 3 and 5).
#   bench/tests/sandbox-release-test.sh
# 1. The signed Release app carries exactly two entitlements:
#    com.apple.security.app-sandbox and
#    com.apple.security.files.user-selected.read-write, both true.
# 2. The Release app has container-migration.plist, naming the old settings.
# 3. Settings move: a copy of the Release app under a scratch bundle ID, with
#    a settings file saved the unsandboxed way, finds that file in its new
#    container after its first launch, and the old file is gone.
# 4. Control: a copy that never saved settings has no probe in its
#    container, so check 3 cannot pass on a value from anywhere else.
# Measured 2026-10-25 on macOS 27: a copy WITHOUT the manifest also found
# its settings moved (the system moves the settings file on the first
# sandboxed launch by itself). The manifest stays as the documented way.
# Never reads or writes the user's real settings file or container: every
# path here uses a scratch bundle ID. The scratch containers go to the Trash.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/Release/QuickEdit.app"
ENTITLEMENTS="$ROOT/QuickEdit/Resources/QuickEdit.entitlements"
WORK="$(mktemp -d -t qe-sandbox-release-test)"
PIDS=()
SCRATCH_IDS=()
cleanup() {
    local pid id
    for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
    for id in ${SCRATCH_IDS[@]+"${SCRATCH_IDS[@]}"}; do
        rm -f "$HOME/Library/Preferences/$id.plist"
        if [ -e "$HOME/Library/Containers/$id" ]; then
            /usr/bin/trash "$HOME/Library/Containers/$id" >/dev/null 2>&1 \
                || echo "NOTE: could not move the scratch container $HOME/Library/Containers/$id to the Trash"
        fi
    done
    rm -rf "$WORK"
}
trap cleanup EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

"$ROOT/build.sh" release >"$WORK/release.log" 2>&1 || { tail -5 "$WORK/release.log"; echo "FAIL: Release build"; exit 1; }
grep -E '^SIGNING:' "$WORK/release.log"

# 1. Exactly the two entitlements, both true.
codesign -d --entitlements - --xml "$APP" 2>/dev/null >"$WORK/ent.plist"
echo "codesign -d --entitlements - on $APP:"
codesign -d --entitlements - "$APP" 2>&1 | sed 's/^/  /'
keys="$(plutil -convert json -o - "$WORK/ent.plist" 2>/dev/null \
    | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(f"{k}={str(v).lower()}" for k,v in sorted(d.items())))')"
want="com.apple.security.app-sandbox=true com.apple.security.files.user-selected.read-write=true"
if [ "$keys" = "$want" ]; then
    pass "Release entitlements are exactly: $want"
else
    fail "Release entitlements are '${keys:-unreadable}', want '$want'"
fi

# 2. The manifest is in the Release app and names the old settings file.
MANIFEST="$APP/Contents/Resources/container-migration.plist"
if [ -f "$MANIFEST" ] && plutil -extract Move.0 raw "$MANIFEST" 2>/dev/null \
    | grep -qx '${Library}/Preferences/dev.yili.QuickEdit.plist'; then
    pass "Release app has container-migration.plist moving \${Library}/Preferences/dev.yili.QuickEdit.plist"
else
    fail "Release app lacks a container-migration.plist that moves the old settings"
fi

# Makes a copy of the Release app under bundle ID $1, with the manifest
# rewritten for that ID ($2 = with) or removed ($2 = without), signed ad hoc
# with the shipped entitlements. Prints the copy's path.
make_copy() {
    local id="$1" mode="$2" copy="$WORK/$1.app"
    ditto "$APP" "$copy"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$copy/Contents/Info.plist"
    if [ "$mode" = with ]; then
        sed "s/dev\.yili\.QuickEdit\.plist/$id.plist/" "$MANIFEST" >"$WORK/manifest.plist"
        cp "$WORK/manifest.plist" "$copy/Contents/Resources/container-migration.plist"
    else
        rm -f "$copy/Contents/Resources/container-migration.plist"
    fi
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$copy" >/dev/null 2>&1 \
        || { echo "FAIL: signing $copy"; return 1; }
    echo "$copy"
}

# Saves a probe setting for $1 the way the unsandboxed app did, launches the
# copy $2 once (binary started directly, so Launch Services never offers the
# copy for opening .txt files), waits for its container, then stops it.
# Leaves the probe's value from the container in $WORK/$1.found.
first_launch() {
    local id="$1" copy="$2" token="$3" old="$HOME/Library/Preferences/$1.plist"
    local box="$HOME/Library/Containers/$1/Data/Library/Preferences/$1.plist"
    local i
    if [ -n "$token" ]; then
        defaults write "$id" QEMigrationProbe -string "$token"
        for i in $(seq 1 50); do [ -f "$old" ] && break; sleep 0.1; done
        [ -f "$old" ] || { echo "FAIL: defaults did not write $old"; return 1; }
    fi
    "$copy/Contents/MacOS/QuickEdit" -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO \
        >"$WORK/$id.out" 2>&1 &
    local pid=$!
    PIDS+=("$pid")
    echo "started $id as PID $pid"
    for i in $(seq 1 100); do [ -d "$HOME/Library/Containers/$id/Data" ] && break; sleep 0.1; done
    sleep 2
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    echo "stopped PID $pid"
    # The container's file itself, not cfprefsd's view of it.
    plutil -extract QEMigrationProbe raw "$box" >"$WORK/$id.found" 2>/dev/null || true
    [ -f "$old" ] && echo yes >"$WORK/$id.oldleft" || echo no >"$WORK/$id.oldleft"
    lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$lsregister" -u "$copy" >/dev/null 2>&1 || true
}

# 3. With the manifest: the settings move into the container.
ID="dev.yili.QuickEdit.migtest-$$-$RANDOM"
SCRATCH_IDS+=("$ID")
TOKEN="moved-$RANDOM"
if COPY="$(make_copy "$ID" with)"; then
    first_launch "$ID" "$COPY" "$TOKEN"
    found="$(cat "$WORK/$ID.found" 2>/dev/null)"
    if [ "$found" = "$TOKEN" ] && [ "$(cat "$WORK/$ID.oldleft")" = no ]; then
        pass "settings saved before the sandbox are in the new container after the first launch"
    else
        fail "settings move: container value '${found:-none}' (want $TOKEN), old file left: $(cat "$WORK/$ID.oldleft" 2>/dev/null)"
    fi
else
    fail "could not make the scratch copy"
fi

# 4. Control: no saved settings, no probe in the container.
ID2="dev.yili.QuickEdit.migtest-$$-$RANDOM-none"
SCRATCH_IDS+=("$ID2")
if COPY2="$(make_copy "$ID2" with)"; then
    first_launch "$ID2" "$COPY2" ""
    found="$(cat "$WORK/$ID2.found" 2>/dev/null)"
    if [ -z "$found" ] && [ -d "$HOME/Library/Containers/$ID2/Data" ]; then
        pass "control: a copy that saved no settings has none in its container"
    else
        fail "control: container value '${found:-none}', container made: $([ -d "$HOME/Library/Containers/$ID2/Data" ] && echo yes || echo no)"
    fi
else
    fail "could not make the control copy"
fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
