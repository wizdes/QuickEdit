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
# Read ioreg into a variable first: under pipefail, `grep -q` quitting early
# can SIGPIPE an earlier stage and turn "locked" into "not locked".
reg="$(ioreg -n Root -d1 -a)" || { echo "FAILED: ioreg failed; cannot tell whether the screen is locked" >&2; exit 1; }
if grep -A1 CGSSessionScreenIsLocked <<<"$reg" | grep '<true/>' >/dev/null; then
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

# launchbench exits 1 on missing samples, missing ready stamps or a failed
# CSV write; pipefail carries that exit through tee.
"$BIN" --runs "$RUNS" --warmups 2 --csv "$OUT/results.csv" --ready-log QuickEdit "${targets[@]}" \
    2>&1 | tee "$OUT/bench.log"
# Belt and braces: the CSV must exist with a row per target and metric.
csv="$OUT/results.csv"
[ -s "$csv" ] || { echo "FAILED: no results CSV at $csv" >&2; exit 1; }
grep -q '^QuickEdit,keystroke_ready,' "$csv" || { echo "FAILED: no QuickEdit keystroke_ready row in $csv" >&2; exit 1; }
for t in "${targets[@]}"; do
    grep -q "^${t%%=*},window_visible," "$csv" || { echo "FAILED: no ${t%%=*} window_visible row in $csv" >&2; exit 1; }
done
echo "results: $csv"
