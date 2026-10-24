#!/bin/bash
# Builds Apple's TextEdit sample (reference/apple) as build/reference/TextEditReference.app.
# Doc B section 6. Works on a copy in $TMPDIR and never edits reference/.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}"
TMP="${TMP%/}"
SRC="$TMP/qe-ref-src"
OBJ="$TMP/qe-ref-obj"
SYM="$REPO/build/reference-sym"
OUT_DIR="$REPO/build/reference"
OUT_APP="$OUT_DIR/TextEditReference.app"
LOG="$REPO/build/reference-build.log"

echo "reference: copying reference/apple to $SRC"
rm -rf "$SRC"
mkdir -p "$SRC" "$REPO/build"
cp -R "$REPO/reference/apple/." "$SRC/"

# 1. The six English.lproj/*.strings files ship as binary plists; Xcode 27 rejects them.
#    Turn each into a UTF-8 text .strings file.
converted=0
for f in "$SRC"/English.lproj/*.strings; do
  if file "$f" | grep -q 'binary property list'; then
    python3 -I - "$f" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as fh:
    table = plistlib.load(fh)
def q(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'
lines = [f"{q(k)} = {q(v)};" for k, v in sorted(table.items())]
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
PY
    plutil -lint "$f" >/dev/null
    converted=$((converted + 1))
  fi
done
echo "reference: converted $converted binary .strings files to text"
if [ "$converted" -ne 6 ]; then
  echo "reference: FAILED, expected 6 binary .strings files, found $converted" >&2
  exit 1
fi

# 2. The project marks the .strings files as UTF-16 (fileEncoding = 10). Mark everything UTF-8.
sed -i '' -E 's/fileEncoding = [0-9]+;/fileEncoding = 4;/g' "$SRC/TextEdit.xcodeproj/project.pbxproj"

# 3. Build for Apple silicon. Without ARCHS the build "succeeds" with no binary.
echo "reference: building (log: $LOG)"
rm -rf "$SYM"
if ! xcodebuild -project "$SRC/TextEdit.xcodeproj" -target TextEdit -configuration Release \
    ARCHS=arm64 VALID_ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- \
    SYMROOT="$SYM" OBJROOT="$OBJ" build >"$LOG" 2>&1; then
  grep -E 'error:|BUILD FAILED' "$LOG" | head -20 >&2
  echo "reference: FAILED, xcodebuild failed (log: $LOG)" >&2
  exit 1
fi
echo "reference: $(grep -cE '^/.*: warning: ' "$LOG" || true) compiler warnings, $(grep -cE '^/.*: error: ' "$LOG" || true) compiler errors"

BUILT="$SYM/Release/TextEdit.app"
if [ ! -x "$BUILT/Contents/MacOS/TextEdit" ]; then
  echo "reference: FAILED, $BUILT/Contents/MacOS/TextEdit missing" >&2
  exit 1
fi

# 4. Rename, give it its own bundle ID, re-sign ad-hoc.
rm -rf "$OUT_APP"
mkdir -p "$OUT_DIR"
ditto "$BUILT" "$OUT_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.yili.TextEditReference' "$OUT_APP/Contents/Info.plist"
codesign --force --deep --sign - "$OUT_APP" >/dev/null 2>&1
codesign --verify "$OUT_APP"

if [ ! -x "$OUT_APP/Contents/MacOS/TextEdit" ]; then
  echo "reference: FAILED, $OUT_APP/Contents/MacOS/TextEdit missing" >&2
  exit 1
fi
echo "reference: OK $OUT_APP ($(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$OUT_APP/Contents/Info.plist"))"
