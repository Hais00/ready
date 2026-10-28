#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
cd "$(dirname "$0")/.."
snapshot=""
case "$#" in
  0) ;;
  2) [ "$1" = "--from-snapshot" ] || { echo "usage: $0 [--from-snapshot /path/v2-snapshot]" >&2; exit 64; }
     snapshot="$2" ;;
  *) echo "usage: $0 [--from-snapshot /path/v2-snapshot]" >&2; exit 64 ;;
esac
mkdir -p "$PWD/Build"
stage=$(mktemp -d "$PWD/Build/.ready-app.XXXXXX")
app="$stage/ready.app"
final="$PWD/Build/ready.app"
previous=""
cleanup() {
  if [ ! -e "$final" ] && [ -n "$previous" ] && [ -e "$previous" ]; then
    mv "$previous" "$final"
  fi
  rm -rf "$stage"
}
trap cleanup EXIT HUP INT TERM
if [ -n "$snapshot" ]; then
  # Strict verification only: this branch invokes no SwiftPM/clang and refuses v1.
  binary=$(python3 Scripts/frontend_snapshot.py verify "$snapshot")
else
  python3 Scripts/frontend_snapshot.py capture-inputs --output "$stage/build-inputs.json"
  sh Scripts/build_overlay.sh
  sh Scripts/build_session_host.sh
  swift build -c release --product M1Launcher --jobs 2
  mkdir -p "$PWD/Build/AppBuildSnapshots"
  snapshot="$PWD/Build/AppBuildSnapshots/release-$(date +%Y%m%d%H%M%S)-$$"
  binary=$(python3 Scripts/frontend_snapshot.py record --inputs "$stage/build-inputs.json" \
    --products "$PWD/.build/release" --destination "$snapshot")
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/ready"
python3 Scripts/package_frontend.py "$app/Contents/Resources/ReadySupport"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.ready.launcher</string>
<key>CFBundleName</key><string>ready</string>
<key>CFBundleExecutable</key><string>ready</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
/usr/bin/codesign --verify --strict "$app/Contents/Resources/ReadySupport/Build/ReadySessionHost"
/usr/bin/codesign --verify --strict "$app/Contents/Resources/ReadySupport/Build/libReadyOverlay.dylib"
# Recheck exact sources/support before signing/publication too. Documentation and
# packaging resources may change independently; compiled inputs may not.
python3 Scripts/frontend_snapshot.py verify "$snapshot" >/dev/null
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
if [ -e "$final" ]; then
  mkdir -p "$PWD/Build/AppBackups"
  previous="$PWD/Build/AppBackups/ready-$(date +%Y%m%d%H%M%S)-$$.app"
  mv "$final" "$previous"
fi
mv "$app" "$final"
printf '%s\n' "$final"
