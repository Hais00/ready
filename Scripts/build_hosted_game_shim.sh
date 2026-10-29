#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/Build"
SDK=$(xcrun --show-sdk-path)
STAGE=$(mktemp -d "$ROOT/Build/.ready-hosted-game-build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
fingerprint_inputs() {
  for source in "$ROOT/NativeEmbedding/ReadyHostedGameShim.m" \
      "$ROOT/Scripts/build_hosted_game_shim.sh" "$ROOT/Sources/ReadyHostedView/include/"*.h; do
    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    /usr/bin/shasum -a 256 "$source"
  done
}
fingerprint_inputs > "$STAGE/inputs.before"
# Only our GPL shim/protocol is compiled. Never re-sign or patch a guest game.
# Publish a fresh verified inode; a running guest may still map the previous one.
xcrun clang -fobjc-arc -fblocks -std=gnu11 -O2 -dynamiclib \
  -arch arm64 -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=14.0 \
  -Wno-deprecated-declarations \
  -framework Cocoa -framework Metal -framework QuartzCore -framework IOSurface \
  -framework CoreGraphics -I "$ROOT/Sources/ReadyHostedView/include" \
  -install_name @rpath/libReadyHostedGame.dylib \
  "$ROOT/NativeEmbedding/ReadyHostedGameShim.m" -o "$STAGE/libReadyHostedGame.dylib"
architectures=$(xcrun lipo -archs "$STAGE/libReadyHostedGame.dylib")
case "$architectures" in
  "arm64 x86_64"|"x86_64 arm64") ;;
  *) echo "Hosted-game shim must contain exactly arm64 and x86_64" >&2; exit 65 ;;
esac
codesign --force --sign - "$STAGE/libReadyHostedGame.dylib"
codesign --verify --strict "$STAGE/libReadyHostedGame.dylib"
fingerprint_inputs > "$STAGE/inputs.after"
/usr/bin/cmp -s "$STAGE/inputs.before" "$STAGE/inputs.after" || {
  echo "Hosted-game source/protocol/recipe changed during build; not publishing" >&2
  exit 65
}
mv -f "$STAGE/libReadyHostedGame.dylib" "$ROOT/Build/libReadyHostedGame.dylib"
printf '%s\n' "Built universal Ready hosted-game shim in $ROOT/Build"
