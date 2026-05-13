#!/usr/bin/env bash
#
# Rebuild assets/AppIcon.icns from assets/AppIcon.svg.
# Generates the 10 required .iconset sizes via rsvg-convert, then runs
# iconutil to produce the .icns. Commit AppIcon.icns; the .iconset
# directory is intermediate (gitignored).
#
# Requires: rsvg-convert (brew install librsvg), iconutil (macOS built-in).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/assets/AppIcon.svg"
ICONSET="$REPO_ROOT/assets/AppIcon.iconset"
OUT="$REPO_ROOT/assets/AppIcon.icns"

[[ -f "$SRC" ]] || { echo "ERROR: $SRC missing" >&2; exit 1; }
command -v rsvg-convert >/dev/null || { echo "ERROR: rsvg-convert not found (brew install librsvg)" >&2; exit 1; }

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Apple's 10 required sizes for a complete macOS iconset.
sizes=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)
for entry in "${sizes[@]}"; do
  size="${entry%%:*}"
  name="${entry##*:}"
  rsvg-convert -w "$size" -h "$size" "$SRC" -o "$ICONSET/$name"
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "✓ Rebuilt $OUT ($(du -h "$OUT" | awk '{print $1}'))"
