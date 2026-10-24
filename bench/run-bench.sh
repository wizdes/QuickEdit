#!/bin/bash
# Launch race (Doc B section 4): QuickEdit vs system TextEdit, plus the
# reference TextEdit build when present. Interleaved rounds, 2 warm-ups.
#   bench/run-bench.sh [runs]     (default 5)
# QuickEdit reports keystroke-ready from its QUICKEDIT_LAUNCH_LOG stamp; every
# app reports window-visible. CSV goes to build/bench-<time>/results.csv.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${1:-5}"
OUT="$ROOT/build/bench-$(date +%Y%m%d-%H%M%S)"
APP="$ROOT/build/Release/QuickEdit.app"
REF="$ROOT/build/reference/TextEditReference.app"
BIN="$ROOT/bench/bin/launchbench"
mkdir -p "$OUT" "$ROOT/bench/bin"

[ -x "$APP/Contents/MacOS/QuickEdit" ] || { echo "FAILED: $APP missing; run ./build.sh first" >&2; exit 1; }
if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
    echo "FAILED: the screen is locked; launch timing needs an unlocked screen" >&2
    exit 1
fi

if [[ ! -x "$BIN" || "$ROOT/bench/launchbench.swift" -nt "$BIN" ]]; then
    echo "== compiling harness"
    xcrun swiftc -O "$ROOT/bench/launchbench.swift" -o "$BIN"
fi

targets=(QuickEdit="$APP" TextEdit=/System/Applications/TextEdit.app)
if [ -x "$REF/Contents/MacOS/TextEdit" ]; then
    targets+=(TextEditReference="$REF")
fi

{
    date
    sw_vers
    sysctl -n hw.model
    echo "load: $(sysctl -n vm.loadavg)"
    echo "QuickEdit signature:"
    codesign -dv "$APP" 2>&1 | grep -E "^(Authority|Signature|TeamIdentifier|CodeDirectory)" || true
    echo "running apps of interest:"
    pgrep -fl "TextEdit|QuickEdit" || true
} > "$OUT/state.txt"
cat "$OUT/state.txt"

"$BIN" --runs "$RUNS" --warmups 2 --csv "$OUT/results.csv" --ready-log QuickEdit "${targets[@]}" \
    2>&1 | tee "$OUT/bench.log"
echo "results: $OUT/results.csv"
