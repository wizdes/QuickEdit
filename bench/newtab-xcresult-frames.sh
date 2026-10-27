#!/bin/bash
# The new-tab frame check for a terminal without Screen Recording permission (1.2.0 change 5).
# XCTest records the screen itself: this runs QuickEditUITests/NewTabRecordingUITests alone with
# the scheme's screen recording on (only for this run; the next ./build.sh regenerates the
# scheme), exports the recording from the result bundle, and writes every distinct frame with
# bench/frames.swift. Frames come in clusters after each Cmd+T (the test waits 1.5 s before
# each): from one tab and from two tabs. Look at the frames to judge them; the count of each
# cluster is printed.
# Needs: an unlocked screen and nobody typing (UI test rules).
# Usage: bench/newtab-xcresult-frames.sh [OUT_DIR]   (default build/newtab-xcresult)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/newtab-xcresult}"
cd "$ROOT"
./build.sh uicheck
rm -rf "$OUT"; mkdir -p "$OUT/attachments" "$OUT/frames" "$ROOT/build/module-cache" "$ROOT/bench/bin"
export CLANG_MODULE_CACHE_PATH="$ROOT/build/module-cache" SWIFT_MODULE_CACHE_PATH="$ROOT/build/module-cache"
if [[ ! -x "$ROOT/bench/bin/frames" || "$ROOT/bench/frames.swift" -nt "$ROOT/bench/bin/frames" ]]; then
    xcrun swiftc -O "$ROOT/bench/frames.swift" -o "$ROOT/bench/bin/frames"
fi
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" --quiet
SCHEME="$ROOT/QuickEdit.xcodeproj/xcshareddata/xcschemes/QuickEdit.xcscheme"
python3 -I - "$SCHEME" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
text, n = re.subn(r'<TestAction\b', '<TestAction\n      preferredScreenCaptureFormat = "screenRecording"\n      systemAttachmentLifetime = "keepAlways"', text, count=1)
if n != 1:
    sys.exit("NEWTAB FAIL no TestAction in " + path)
open(path, "w").write(text)
PY
RESULT="$OUT/recording.xcresult"
status=0
perl -e 'alarm 600; exec @ARGV' xcodebuild test -project "$ROOT/QuickEdit.xcodeproj" -scheme QuickEdit -configuration Debug \
    -derivedDataPath "$ROOT/build/DerivedData" -resultBundlePath "$RESULT" -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_IDENTITY=- -only-testing:QuickEditUITests/NewTabRecordingUITests </dev/null >"$OUT/xcodebuild.log" 2>&1 || status=$?
pkill -f "$ROOT/build/DerivedData/Build/Products/Debug/QuickEdit.app/Contents/MacOS/QuickEdit" 2>/dev/null || true
[[ "$status" -eq 0 ]] || { tail -20 "$OUT/xcodebuild.log" >&2; echo "NEWTAB FAIL xcodebuild exited $status (log: $OUT/xcodebuild.log)" >&2; exit 1; }
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT/attachments" >/dev/null
VIDEO="$(find "$OUT/attachments" -type f \( -name '*.mp4' -o -name '*.mov' \) | head -1)"
[[ -n "$VIDEO" ]] || { ls "$OUT/attachments" >&2; echo "NEWTAB FAIL the result bundle holds no screen recording" >&2; exit 1; }
echo "NEWTAB recording: $VIDEO"
"$ROOT/bench/bin/frames" "$VIDEO" "$OUT/frames" 60 | tee "$OUT/frames.txt" | tail -1
# Clusters: frames written less than 0.4 s apart belong together.
python3 -I - "$OUT/frames" <<'PY'
import os, sys
d = sys.argv[1]
times = sorted(float(f.split('_')[1][:-4]) for f in os.listdir(d))
clusters, current = [], []
for t in times:
    if current and t - current[-1] > 0.4:
        clusters.append(current); current = []
    current.append(t)
if current: clusters.append(current)
for c in clusters:
    print(f"NEWTAB cluster at {c[0]:.2f} s: {len(c)} frames ({' '.join(f'{t:.3f}' for t in c)})")
PY
