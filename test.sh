#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
TARGET="arm64-apple-macosx14.0"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/livewall-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

if [ ! -d "$SDK" ]; then
  SDK="$(xcrun --show-sdk-path)"
fi

swiftc \
  -sdk "$SDK" \
  -target "$TARGET" \
  -o "$TEST_DIR/WallpaperProjectLoaderTests" \
  "$ROOT/Sources/LiveWall/WallpaperProject.swift" \
  "$ROOT/Sources/LiveWall/SceneWallpaper.swift" \
  "$ROOT/Sources/LiveWall/SteamWorkshop.swift" \
  "$ROOT/Tests/WallpaperProjectLoaderTests.swift" \
  -framework ImageIO \
  -framework CoreGraphics

"$TEST_DIR/WallpaperProjectLoaderTests"
