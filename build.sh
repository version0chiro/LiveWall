#!/bin/bash
# Build LiveWall.app — a menu-bar live wallpaper app.
# Uses the SDK that matches the Command Line Tools compiler.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/LiveWall.app"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
TARGET="arm64-apple-macosx14.0"

# Fall back to the default SDK if the pinned one is gone.
if [ ! -d "$SDK" ]; then
  SDK="$(xcrun --show-sdk-path)"
  echo "warning: MacOSX15.4 SDK not found, using $SDK (may hit compiler/SDK mismatch)"
fi

echo "Building with SDK: $SDK"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -O \
  -o "$APP/Contents/MacOS/LiveWall" \
  "$ROOT"/Sources/LiveWall/*.swift \
  -framework AppKit \
  -framework AVFoundation \
  -framework WebKit \
  -framework ScreenCaptureKit \
  -framework Accelerate \
  -framework AudioToolbox \
  -framework CoreMedia \
  -framework CoreImage \
  -framework ImageIO \
  -framework Metal \
  -framework MetalKit

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>LiveWall</string>
    <key>CFBundleDisplayName</key>     <string>LiveWall</string>
    <key>CFBundleIdentifier</key>      <string>com.livewall.app</string>
    <key>CFBundleVersion</key>         <string>4</string>
    <key>CFBundleShortVersionString</key><string>0.6.0</string>
    <key>CFBundleExecutable</key>      <string>LiveWall</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>LiveWall captures system audio only when you enable audio visualizers.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>LiveWall reads now-playing information from Music and Spotify only when you enable media widgets.</string>
</dict>
</plist>
PLIST

# Ad-hoc codesign so macOS will launch it locally.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "note: codesign skipped"

echo "Built: $APP"
echo "Run:   open \"$APP\"   (look for the photo icon in the menu bar)"
