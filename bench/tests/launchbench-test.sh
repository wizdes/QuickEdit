#!/bin/bash
# Checks for bench/launchbench.swift failure handling (M1 review rows 9, 10).
#   bench/tests/launchbench-test.sh
# Launches only a fake app built here (bundle id dev.yili.qe-bench-fake);
# never touches TextEdit or QuickEdit.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d -t qe-launchbench-test)"
FAKE="$WORK/FakeBench.app"
BIN="$WORK/launchbench"
cleanup() {
    pkill -f "$FAKE/Contents/MacOS/FakeBench" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

mkdir -p "$FAKE/Contents/MacOS"
xcrun swiftc -O "$ROOT/bench/tests/fake-app.swift" -o "$FAKE/Contents/MacOS/FakeBench" || exit 1
cat >"$FAKE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.yili.qe-bench-fake</string>
<key>CFBundleExecutable</key><string>FakeBench</string>
<key>CFBundleName</key><string>FakeBench</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$FAKE" >/dev/null 2>&1 || exit 1
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

echo "launchbench-test: $fails failure(s)"
[ "$fails" -eq 0 ]
