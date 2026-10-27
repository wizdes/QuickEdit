#!/bin/bash
# Records the screen while Cmd+T opens a new tab and keeps every distinct frame, so the
# new-tab change can be judged by eye and by count (1.2.0 change 5; adapted from Kelpi's
# bench/newtab-frames.sh, commit 571ac9f). Two runs: from one tab (no tab bar yet) and from
# two tabs. The one-tab run is checked: after the app settles, the first changed frame must
# already be the finished state (no frame with the old tab selected under a new bar, no blank
# text). The two-tab run only reports its frame count; the tab's own animation is wanted.
# Needs: an unlocked, awake display; QuickEdit allowed to come to the front; and the terminal
# allowed to control the computer (osascript) and to record the screen (screencapture -V).
# Usage: bench/newtab-frames.sh [APP] [OUT_DIR]
#   APP      default: the Debug app ./build.sh test builds (build/DerivedData/.../Debug)
#   OUT_DIR  default: build/newtab-frames
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/DerivedData/Build/Products/Debug/QuickEdit.app}"
BIN="$APP/Contents/MacOS/QuickEdit"
OUT="${2:-$ROOT/build/newtab-frames}"
[[ -x "$BIN" ]] || { echo "NEWTAB FAIL missing $BIN; build it first (./build.sh only QuickEditTests/AboutPanelTests)" >&2; exit 1; }
mkdir -p "$ROOT/build/module-cache" "$ROOT/bench/bin" "$OUT"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/module-cache" SWIFT_MODULE_CACHE_PATH="$ROOT/build/module-cache"
if [[ ! -x "$ROOT/bench/bin/frames" || "$ROOT/bench/frames.swift" -nt "$ROOT/bench/bin/frames" ]]; then
    xcrun swiftc -O "$ROOT/bench/frames.swift" -o "$ROOT/bench/bin/frames"
fi
NAME="$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' "$APP/Contents/Info.plist")"
SUITE="dev.yili.QuickEdit.newtab-frames"
FAILED=0
record() {
    local name="$1" extra_tabs="$2"
    local dir="$OUT/$name" pid region i
    rm -rf "$dir" "$dir.mov"; mkdir -p "$dir"
    # Its own settings suite (Debug builds only), emptied first; no saved windows.
    "$BIN" -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO \
        -QETestDefaultsSuite "$SUITE" -QETestDefaultsSuiteReset YES -AppleInterfaceStyle Light &
    pid=$!
    sleep 2
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true"
    sleep 1
    for ((i = 0; i < extra_tabs; i++)); do
        osascript -e 'tell application "System Events" to keystroke "t" using command down'
        sleep 1
    done
    region="$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to get {position, size} of window 1" | tr -d ' ')"
    screencapture -x -V 3 -R "$region" "$dir.mov" &
    local capture=$!
    sleep 1.2
    osascript -e 'tell application "System Events" to keystroke "t" using command down'
    wait "$capture" || { echo "NEWTAB FAIL screencapture failed (Screen Recording permission?)" >&2; kill "$pid" 2>/dev/null || true; return 1; }
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    [[ -s "$dir.mov" ]] || { echo "NEWTAB FAIL no recording at $dir.mov" >&2; return 1; }
    "$ROOT/bench/bin/frames" "$dir.mov" "$dir" 60
}
echo "NEWTAB $NAME one tab: recording"
record one 0 || exit 1
# A frame is written only when it differs from the last one by more than the caret blink
# (bench/frames.swift). After the app has settled (0.9 s), the one-tab run must write exactly
# one frame: the switch to the finished new tab. A second frame is an in-between state.
if python3 -I - "$OUT/one" <<'PY'
import os, sys
d = sys.argv[1]
frames = sorted(os.listdir(d))
def t(name): return float(name.split('_')[1][:-4])
late = [f for f in frames if t(f) >= 0.9]
print(f"NEWTAB one tab: {len(frames)} frames written in all, {len(late)} after 0.9 s: {' '.join(late)}")
if len(late) != 1:
    print("NEWTAB FAIL one tab: want exactly one changed frame (the finished new tab); more means an in-between frame (old tab under a new bar, or blank text), none means Cmd+T did not open a tab; look at " + d)
    sys.exit(1)
print("NEWTAB PASS one tab: the bar came up with the new tab selected in one step")
PY
then :; else FAILED=1; fi
echo "NEWTAB $NAME two tabs: recording"
record two 1 || exit 1
echo "NEWTAB two tabs: $(ls "$OUT/two" | wc -l | tr -d ' ') distinct frames; look at $OUT/two to judge the animation"
exit "$FAILED"
