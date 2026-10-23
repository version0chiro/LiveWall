#!/bin/bash
# Regenerate Assets/LiveWall.icns from the repository's SVG artwork.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Assets/AppIcon.svg"
OUTPUT="$ROOT/Assets/LiveWall.icns"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/livewall-icon.XXXXXX")"
ICONSET="$WORK_DIR/LiveWall.iconset"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$ICONSET"
qlmanage -t -s 1024 -o "$WORK_DIR" "$SOURCE" >/dev/null
SOURCE_PNG="$(find "$WORK_DIR" -maxdepth 1 -type f -name '*.png' -print -quit)"
if [ -z "$SOURCE_PNG" ]; then
  echo "error: Quick Look did not render $SOURCE" >&2
  exit 1
fi

render() {
  local pixels="$1"
  local filename="$2"
  sips -z "$pixels" "$pixels" "$SOURCE_PNG" \
    --out "$ICONSET/$filename" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Generated: $OUTPUT"
