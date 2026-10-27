#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
cd "$(dirname "$0")/.."
sh Scripts/build_overlay.sh
sh Scripts/build_session_host.sh
swift build -c release
app="$PWD/Build/ready.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/M1Launcher "$app/Contents/MacOS/ready"
printf '%s\n' "$PWD" > "$app/Contents/Resources/development-root.txt"
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
/usr/bin/codesign --force --sign - "$app"
printf '%s\n' "$app"
