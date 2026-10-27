#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
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
printf '%s\n' "Built universal overlay and universal Metal probe in $ROOT/Build"
