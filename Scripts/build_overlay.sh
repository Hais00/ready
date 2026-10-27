#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/Build"
SDK=$(xcrun --show-sdk-path)
xcrun clang -fobjc-arc -fblocks -O2 -g -dynamiclib -arch arm64 -arch x86_64 \
  -isysroot "$SDK" -mmacosx-version-min=14.0 -Wno-unguarded-availability-new \
  -framework Foundation -framework AppKit -framework Metal -framework QuartzCore \
  -framework CoreText -framework GameController \
  -install_name @rpath/libReadyOverlay.dylib \
  "$ROOT/Overlay/ReadyOverlay.m" -o "$ROOT/Build/libReadyOverlay.dylib"
xcrun clang -fobjc-arc -fblocks -O2 -g -arch arm64 -arch x86_64 \
  -isysroot "$SDK" -mmacosx-version-min=14.0 -Wno-unguarded-availability-new \
  -framework Foundation -framework AppKit -framework Metal -framework QuartzCore \
  -framework CoreGraphics -framework ImageIO \
  "$ROOT/Synthetic/ReadyMetalProbe.m" -o "$ROOT/Build/ReadyMetalProbe"
codesign --force --sign - "$ROOT/Build/libReadyOverlay.dylib" "$ROOT/Build/ReadyMetalProbe"
APP="$ROOT/Build/ReadyMetalProbe.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Build/ReadyMetalProbe" "$APP/Contents/MacOS/ReadyMetalProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.ready.MetalProbe</string>
<key>CFBundleExecutable</key><string>ReadyMetalProbe</string>
<key>CFBundleName</key><string>Ready Metal Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '%s\n' "Built universal overlay and universal Metal probe in $ROOT/Build"
