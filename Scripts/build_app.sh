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
refresh_registration=0
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
cleanup() {
  if [ ! -e "$final" ] && [ -n "$previous" ] && [ -e "$previous" ]; then
    mv "$previous" "$final"
  fi
  # Refresh only this exact published (or restored) bundle. Never scan/reset the
  # Launch Services database or register the recoverable, non-app backup.
  if [ "$refresh_registration" = 1 ] && [ -d "$final" ] && [ -x "$lsregister" ]; then
    "$lsregister" -f "$final" >/dev/null 2>&1 || echo "Could not refresh Launch Services for $final" >&2
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
  previous="$PWD/Build/AppBackups/ready-$(date +%Y%m%d%H%M%S)-$$.ready-backup"
  # Inventory is a sibling, so changing the extension preserves every bundle byte.
  python3 - "$final" "$previous" <<'PY'
import hashlib, os, stat, sys
from pathlib import Path
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path.cwd() / 'Scripts'))
import frontend_snapshot as snapshot
bundle, destination = map(Path, sys.argv[1:])
if destination.exists() or destination.is_symlink(): raise ValueError('Existing backup is never overwritten')
parent_info = destination.parent.lstat()
if not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid != os.getuid():
    raise ValueError('Owned normal backup directory required')
for path in [bundle, *bundle.rglob('*')]:
    info = path.lstat()
    if info.st_uid != os.getuid() or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
        raise ValueError('Backup must be an owned bundle without aliases/special files')
files = snapshot.tree(bundle)
if not files: raise ValueError('Empty frontend backup refused')
snapshot.write_new(Path(str(destination) + '.manifest.json'), snapshot.encoded({
    'schema': 1, 'kind': 'ready-frontend-backup-v1', 'bundle': destination.name,
    'originalPath': str(bundle), 'files': files,
    'treeFingerprintSHA256': hashlib.sha256(snapshot.encoded(files)).hexdigest(),
}))
PY
  if [ -x "$lsregister" ]; then
    "$lsregister" -u "$final" >/dev/null 2>&1 || echo "Could not unregister previous $final" >&2
  fi
  refresh_registration=1
  mv "$final" "$previous"
fi
refresh_registration=1
mv "$app" "$final"
printf '%s\n' "$final"
