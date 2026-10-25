#!/bin/bash
# M8 n5: TextKit 1 vs TextKit 2 benchmark (vote V1 in docs/decisions.md).
#   bench/tk2bench.sh [runs]     (default 5)
# One fresh process per engine, fixture and run; engines alternate which goes
# first each run. Each worker is killed after 900 s. CSV goes to
# build/tk2bench-<time>.csv; the table goes to stdout and build/tk2bench-<time>.txt.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNS="${1:-5}"
BIN="$ROOT/build/tk2bench"
FIX="$ROOT/bench/fixtures"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="$ROOT/build/tk2bench-$STAMP.csv"
TXT="$ROOT/build/tk2bench-$STAMP.txt"
mkdir -p "$ROOT/build"

for f in 100mb.txt long-line-10mb.txt; do
    [ -s "$FIX/$f" ] || { echo "== making fixtures"; "$ROOT/bench/make-fixtures.sh"; break; }
done
if [[ ! -x "$BIN" || "$ROOT/bench/tk2bench.swift" -nt "$BIN" ]]; then
    echo "== compiling (xcrun swiftc -O)"
    xcrun swiftc -O "$ROOT/bench/tk2bench.swift" -o "$BIN"
fi

{
    date; sw_vers; sysctl -n hw.model; echo "memsize: $(sysctl -n hw.memsize)"
    echo "load: $(sysctl -n vm.loadavg)"
    reg="$(ioreg -n Root -d1 -a)" || { echo "FAILED: ioreg failed" >&2; exit 1; }
    if grep -A1 CGSSessionScreenIsLocked <<<"$reg" | grep '<true/>' >/dev/null; then
        echo "screen: LOCKED (displays may not reach the screen; see draws_* and window_visible)"
    else
        echo "screen: unlocked"
    fi
} | tee "$TXT"

echo "engine,fixture,run,metric,value" > "$CSV"
failures=0
for ((r = 1; r <= RUNS; r++)); do
    if (( r % 2 )); then order=(tk1 tk2); else order=(tk2 tk1); fi
    for f in 100mb.txt long-line-10mb.txt; do
        for e in "${order[@]}"; do
            echo "== run $r/$RUNS $f $e"
            rc=0
            out="$(perl -e 'alarm 900; exec @ARGV' "$BIN" --worker "$e" --file "$FIX/$f" --run "$r" < /dev/null)" || rc=$?
            rows="$(grep '^ROW,' <<<"$out" | cut -d, -f2- || true)"
            [ -n "$rows" ] && echo "$rows" >> "$CSV"
            echo "$e,$f,$r,worker_exit,$rc" >> "$CSV"
            if (( rc != 0 )); then
                # A killed worker is a result, not a harness bug: keep its rows and go on.
                # 137 = SIGKILL (the kernel's low-swap kill), 142 = the 900 s alarm.
                echo "WORKER FAILED: $e $f run $r exited $rc after $(grep -c . <<<"$rows") rows" >&2
                failures=$((failures + 1))
            elif ! grep -q ',type_p95_ms,' <<<"$rows"; then
                echo "WORKER FAILED: $e $f run $r exited 0 with no typing result" >&2
                failures=$((failures + 1))
            fi
            if pgrep -f "$BIN --worker" >/dev/null; then
                echo "FAILED: a worker is still running after it exited" >&2; exit 1
            fi
        done
    done
done

"$BIN" --summarize "$CSV" | tee -a "$TXT"
echo "csv: $CSV"
echo "table: $TXT"
if (( failures )); then echo "FAILED: $failures worker(s) did not finish; see worker_exit rows" | tee -a "$TXT" >&2; exit 1; fi
