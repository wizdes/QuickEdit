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
# 4. Control: a probe saved the unsandboxed way for a copy that is never
#    launched is not in its container, and the old file stays. So check 3
#    passes only because of the first launch, and it reads the container's
#    file, not the probe through cfprefsd. (Before sandbox review J, this
#    check used a copy that saved nothing, which could never fail.)
# 0. The guard: a copy is launched only when its Info.plist names the
#    scratch ID and its manifest names only scratch paths; a copy that kept
#    the real ID is refused (sandbox review A). Every preparation step stops
#    the script when it fails.
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

REAL_ID="dev.yili.QuickEdit"
# Scratch IDs only: dev.yili.QuickEdit.migtest-<pid>-<n>[-control].
is_scratch_id() { [[ "$1" =~ ^dev\.yili\.QuickEdit\.migtest-[0-9]+-[0-9]+(-control)?$ ]]; }

# Exits the whole script: a failed preparation step must never be followed
# by a launch (the copy could run as the real app).
abort() { echo "FAIL: $*" >&2; echo "stopped before any launch of an unchecked copy" >&2; exit 1; }

# Nil output and exit 0 when the copy $2 is safe to launch as scratch ID
# $1: its CFBundleIdentifier is $1, and its manifest, if any, moves only
# files named for $1 (never the real app's settings).
verify_copy() {
    local id="$1" copy="$2" got entry i
    is_scratch_id "$id" || { echo "the ID $id is not a scratch ID"; return 1; }
    got="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$copy/Contents/Info.plist" 2>/dev/null)" \
        || { echo "cannot read the copy's CFBundleIdentifier"; return 1; }
    [ "$got" = "$id" ] || { echo "the copy's CFBundleIdentifier is '$got', not $id"; return 1; }
    local manifest="$copy/Contents/Resources/container-migration.plist"
    [ -e "$manifest" ] || return 0
    plutil -lint -s "$manifest" || { echo "the copy's manifest is not a valid property list"; return 1; }
    for i in $(seq 0 20); do
        entry="$(plutil -extract "Move.$i" raw "$manifest" 2>/dev/null)" || break
        [ "$entry" = "\${Library}/Preferences/$id.plist" ] \
            || { echo "the copy's manifest moves '$entry', not only \${Library}/Preferences/$id.plist"; return 1; }
    done
    if grep -q "$REAL_ID\.plist" "$manifest"; then
        echo "the copy's manifest names the real settings file"; return 1
    fi
    return 0
}

# Makes a copy of the Release app under bundle ID $1, with the manifest
# rewritten for that ID ($2 = with) or removed ($2 = without), signed ad hoc
# with the shipped entitlements, then checked by verify_copy. Prints the
# copy's path. Any failed step ends the script.
make_copy() {
    local id="$1" mode="$2" copy="$WORK/$1.app" problem
    is_scratch_id "$id" || abort "make_copy was given $id, not a scratch ID"
    ditto "$APP" "$copy" || abort "ditto $APP $copy"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$copy/Contents/Info.plist" \
        || abort "PlistBuddy could not set CFBundleIdentifier in $copy"
    if [ "$mode" = with ]; then
        sed "s/dev\.yili\.QuickEdit\.plist/$id.plist/" "$MANIFEST" >"$WORK/manifest.plist" \
            || abort "sed could not rewrite the manifest for $id"
        cp "$WORK/manifest.plist" "$copy/Contents/Resources/container-migration.plist" \
            || abort "cp of the manifest into $copy"
    else
        rm -f "$copy/Contents/Resources/container-migration.plist" || abort "rm of the manifest in $copy"
    fi
    codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$copy" >/dev/null 2>&1 \
        || abort "signing $copy"
    problem="$(verify_copy "$id" "$copy")" || abort "the copy is not safe to launch: $problem"
    echo "$copy"
}

# 0. The guard refuses unsafe copies. A copy that kept the real ID, a
#    manifest that still moves the real settings, and a real ID passed in
#    are each refused; the copies here are never launched.
if [ -d "$APP" ]; then
    GUARD_ID="dev.yili.QuickEdit.migtest-$$-1"
    ditto "$APP" "$WORK/guard.app" || abort "ditto for the guard check"
    guard_fails=0
    verify_copy "$GUARD_ID" "$WORK/guard.app" >/dev/null && guard_fails=$((guard_fails + 1))   # still the real ID
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $GUARD_ID" "$WORK/guard.app/Contents/Info.plist" \
        || abort "PlistBuddy for the guard check"
    verify_copy "$GUARD_ID" "$WORK/guard.app" >/dev/null && guard_fails=$((guard_fails + 1))   # manifest moves the real file
    rm -f "$WORK/guard.app/Contents/Resources/container-migration.plist"
    verify_copy "$GUARD_ID" "$WORK/guard.app" >/dev/null || guard_fails=$((guard_fails + 1))   # now safe
    verify_copy "$REAL_ID" "$WORK/guard.app" >/dev/null && guard_fails=$((guard_fails + 1))    # the real ID
    out="$( (make_copy "$REAL_ID" with) 2>&1)" && guard_fails=$((guard_fails + 1))
    grep -q "not a scratch ID" <<<"$out" || guard_fails=$((guard_fails + 1))
    rm -rf "$WORK/guard.app" "$WORK/$REAL_ID.app"
    if [ "$guard_fails" -eq 0 ]; then
        pass "the guard refuses a copy with the real ID or a manifest naming the real settings"
    else
        abort "the guard let $guard_fails unsafe case(s) through"
    fi
fi

# Saves a probe setting for $1 the way the unsandboxed app did, launches the
# copy $2 once (binary started directly, so Launch Services never offers the
# copy for opening .txt files), waits for its container, then stops it.
# Leaves the probe's value from the container in $WORK/$1.found.
# $4 = nolaunch saves the probe but never starts the copy (check 4).
first_launch() {
    local id="$1" copy="$2" token="$3" launch="${4:-launch}" old="$HOME/Library/Preferences/$1.plist"
    local box="$HOME/Library/Containers/$1/Data/Library/Preferences/$1.plist"
    local i problem
    is_scratch_id "$id" || abort "first_launch was given $id, not a scratch ID"
    problem="$(verify_copy "$id" "$copy")" || abort "refusing to launch $copy: $problem"
    if [ -n "$token" ]; then
        defaults write "$id" QEMigrationProbe -string "$token" || abort "defaults write $id"
        for i in $(seq 1 50); do [ -f "$old" ] && break; sleep 0.1; done
        [ -f "$old" ] || { echo "FAIL: defaults did not write $old"; return 1; }
    fi
    if [ "$launch" = launch ]; then
        "$copy/Contents/MacOS/QuickEdit" -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO \
            >"$WORK/$id.out" 2>&1 &
        local pid=$!
        PIDS+=("$pid")
        echo "started $id as PID $pid"
        for i in $(seq 1 100); do [ -d "$HOME/Library/Containers/$id/Data" ] && break; sleep 0.1; done
        sleep 2
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        echo "stopped PID $pid"
    else
        sleep 2
    fi
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

# 4. Control: the probe is saved, the copy is never launched: no probe
#    in its container (none is made), and the old file is still there.
ID2="dev.yili.QuickEdit.migtest-$$-$RANDOM-control"
SCRATCH_IDS+=("$ID2")
TOKEN2="unmoved-$RANDOM"
if COPY2="$(make_copy "$ID2" with)"; then
    first_launch "$ID2" "$COPY2" "$TOKEN2" nolaunch
    found="$(cat "$WORK/$ID2.found" 2>/dev/null)"
    if [ -z "$found" ] && [ "$(cat "$WORK/$ID2.oldleft")" = yes ]; then
        pass "control: with no launch, the saved probe is not in the container and the old file stays"
    else
        fail "control: container value '${found:-none}' with no launch, old file left: $(cat "$WORK/$ID2.oldleft" 2>/dev/null)"
    fi
else
    fail "could not make the control copy"
fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
