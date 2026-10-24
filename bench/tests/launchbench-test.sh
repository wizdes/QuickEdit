#!/bin/bash
# Checks for bench/launchbench.swift failure handling (M1 review rows 9, 10).
#   bench/tests/launchbench-test.sh
# Launches only fake apps built here; never touches TextEdit or QuickEdit.
# Each fake gets its own bundle id, so two runs at once (two clones) do not
# see each other's fake as "already running".
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d -t qe-launchbench-test)"
FAKE="$WORK/FakeBench.app"
BIN="$WORK/launchbench"
OTHER="$WORK/other/FakeBench.app"
cleanup() {
    pkill -f "$FAKE/Contents/MacOS/FakeBench" 2>/dev/null || true
    pkill -f "$OTHER/Contents/MacOS/FakeBench" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# make_fake <app path>: builds the fake app with a bundle id unique to this
# app (a fresh UUID), signed ad hoc.
make_fake() {
    local app="$1" id
    # Bundle ids allow letters, digits, "-" and "."; uuidgen is unique per call.
    id="dev.yili.qe-bench-fake.$(uuidgen | tr -d '-' | tr 'A-Z' 'a-z')"
    mkdir -p "$app/Contents/MacOS"
    xcrun swiftc -O "$ROOT/bench/tests/fake-app.swift" -o "$app/Contents/MacOS/FakeBench" || return 1
    cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleExecutable</key><string>FakeBench</string>
<key>CFBundleName</key><string>FakeBench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
    codesign --force --sign - "$app" >/dev/null 2>&1
}
bundle_id() { /usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$1/Contents/Info.plist"; }
make_fake "$FAKE" || exit 1
xcrun swiftc -O "$ROOT/bench/launchbench.swift" -o "$BIN" || exit 1
fast=(--runs 1 --warmups 0 --hold 0 --settle 0.2 --timeout 2)
fake_pids() { pgrep -f "$FAKE/Contents/MacOS/FakeBench" || true; }

# Row 9: a target that is already running is not quit; the bench refuses.
"$FAKE/Contents/MacOS/FakeBench" </dev/null >/dev/null 2>&1 &
before=$!
sleep 1
out="$(perl -e 'alarm 120; exec @ARGV' "$BIN" "${fast[@]}" Fake="$FAKE" 2>&1)"; status=$?
if [ "$status" -ne 0 ] && grep -q "already running" <<<"$out" && kill -0 "$before" 2>/dev/null; then
    pass "refuses when the target is already running, and leaves it running"
else
    fail "already-running target (exit $status, pid $before alive: $(kill -0 "$before" 2>/dev/null && echo yes || echo no)): $(tail -2 <<<"$out")"
fi
kill "$before" 2>/dev/null; wait "$before" 2>/dev/null
sleep 0.5

# M2 review row 2: a copy of the target started between rounds is not
# reused or quit; the bench stops with an error that names it.
"$BIN" --runs 2 --warmups 0 --hold 0 --settle 3 --timeout 5 --arg Fake=--window Fake="$FAKE" \
    >"$WORK/between.out" 2>&1 &
bench=$!
# Wait for the bench's own round-1 copy to appear and then go away.
seen=""
for _ in $(seq 1 200); do
    if [ -n "$(fake_pids)" ]; then seen=yes; elif [ -n "$seen" ]; then break; fi
    sleep 0.05
done
"$FAKE/Contents/MacOS/FakeBench" </dev/null >/dev/null 2>&1 &
user=$!
perl -e 'alarm 180; exec @ARGV' sh -c "while kill -0 $bench 2>/dev/null; do sleep 0.2; done"
wait "$bench"; status=$?
out="$(cat "$WORK/between.out")"
if [ -n "$seen" ] && [ "$status" -ne 0 ] && grep -q "not launched by the bench" <<<"$out" && grep -q "$user" <<<"$out" \
    && kill -0 "$user" 2>/dev/null; then
    pass "a copy started between rounds stops the bench, named, and keeps running"
else
    fail "copy started between rounds (round-1 copy seen: ${seen:-no}, exit $status, pid $user alive: $(kill -0 "$user" 2>/dev/null && echo yes || echo no)): $(tail -3 <<<"$out")"
fi
kill "$user" 2>/dev/null; wait "$user" 2>/dev/null
sleep 0.5

# Row 10: no window ever appears -> missing samples -> non-zero exit.
out="$(perl -e 'alarm 300; exec @ARGV' "$BIN" "${fast[@]}" --csv "$WORK/a.csv" Fake="$FAKE" 2>&1)"; status=$?
if [ "$status" -ne 0 ] && grep -qi "missing\|below" <<<"$out"; then
    pass "missing samples fail the run (exit $status)"
else
    fail "missing samples exited $status: $(tail -2 <<<"$out")"
fi
[ -z "$(fake_pids)" ] || fail "fake app left running after the no-window run"

# Row 10: a window but no ready stamp for a --ready-log target -> non-zero exit.
out="$(perl -e 'alarm 300; exec @ARGV' "$BIN" "${fast[@]}" --csv "$WORK/b.csv" --ready-log Fake \
    --arg Fake=--window Fake="$FAKE" 2>&1)"; status=$?
if [ "$status" -ne 0 ] && grep -qi "ready" <<<"$out"; then
    pass "missing ready stamps fail the run (exit $status)"
else
    fail "missing ready stamps exited $status: $(tail -3 <<<"$out")"
fi

# Row 10: a CSV that cannot be written -> non-zero exit.
out="$(perl -e 'alarm 300; exec @ARGV' "$BIN" "${fast[@]}" --csv "$WORK/no-such-dir/c.csv" \
    --arg Fake=--window Fake="$FAKE" 2>&1)"; status=$?
if [ "$status" -ne 0 ] && grep -qi "csv" <<<"$out"; then
    pass "an unwritable CSV fails the run (exit $status)"
else
    fail "unwritable CSV exited $status: $(tail -2 <<<"$out")"
fi
[ -z "$(fake_pids)" ] || fail "fake app left running at the end"

# Two runs at once: another run's fake (built the same way) has its own
# bundle id, and while it runs this run's bench still works.
make_fake "$OTHER" || exit 1
if [ "$(bundle_id "$FAKE")" != "$(bundle_id "$OTHER")" ]; then
    pass "each run's fake has its own bundle id ($(bundle_id "$FAKE"))"
else
    fail "two fakes share the bundle id $(bundle_id "$FAKE"), so two runs at once collide"
fi
"$OTHER/Contents/MacOS/FakeBench" </dev/null >/dev/null 2>&1 &
other=$!
sleep 1
# A window run that fails only at the end (unwritable CSV): fast, and it
# reaches the end only if the other fake did not stop it at the start.
out="$(perl -e 'alarm 300; exec @ARGV' "$BIN" "${fast[@]}" --csv "$WORK/no-such-dir/d.csv" \
    --arg Fake=--window Fake="$FAKE" 2>&1)"; status=$?
if [ "$status" -ne 0 ] && grep -qi "csv" <<<"$out" && ! grep -q "already running" <<<"$out"; then
    pass "another run's fake does not stop this run's bench"
else
    fail "with another run's fake running (exit $status): $(tail -2 <<<"$out")"
fi
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

echo "launchbench-test: $fails failure(s)"
[ "$fails" -eq 0 ]
