#!/bin/bash
# Build and package LiveWall as a drag-to-Applications DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/LiveWall.app"
OUTPUT_DIR="$ROOT/dist"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/livewall-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

"$ROOT/test.sh"
"$ROOT/build.sh"

codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG_NAME="LiveWall-v${VERSION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"

mkdir -p "$OUTPUT_DIR"
rm -f "$DMG_PATH" "$CHECKSUM_PATH"

ditto "$APP" "$STAGING_DIR/LiveWall.app"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "LiveWall ${VERSION}" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"

echo "Packaged: $DMG_PATH"
echo "Checksum: $CHECKSUM_PATH"
