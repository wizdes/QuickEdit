#!/bin/bash
# Builds the three drafts, their PNGs and the comparison sheet.
set -euo pipefail
T="$(cd "$(dirname "$0")" && pwd)"; O="$(dirname "$T")"
python3 -I "$T/make_icons.py" "$O"
mkdir -p "$O/png"
for d in draft-a-caret draft-b-aa draft-c-bolt; do
  for s in 1024 128 32; do "$T/render_png" "$O/$d.svg" "$O/png/$d-$s.png" $s; done
done
python3 -I "$T/make_sheet.py" "$O"
"$T/render_sheet" "$O/sheet.svg" "$O/comparison-sheet.png" 3720 2280
echo "sheet: $O/comparison-sheet.png"
