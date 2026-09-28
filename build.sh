#!/bin/bash
# Builds build/Foldera.app around the SwiftPM binary, ad-hoc signed so it
# runs on this Mac.
#
#   ./build.sh            release build → build/Foldera.app
#   ./build.sh debug      debug build, same place
#   ./build.sh install    release build, then copied to /Applications
set -euo pipefail

cd "$(dirname "$0")"
STEP="${1:-release}"
CONFIG=release
[ "$STEP" = "debug" ] && CONFIG=debug
APP="build/Foldera.app"
NAME="Foldera"
VERSION="0.2.0"
STAGE="beta"   # shown in About Foldera; empty for a final release
BUILD="$(date +%Y%m%d%H%M)"

swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/$NAME"

# The icon is drawn fresh each time from Icon/icon.swift.
rm -rf build/AppIcon.iconset
swift Icon/icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.vladimirperovic.foldera</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>FolderaReleaseStage</key><string>$STAGE</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <!-- Network in the navigation pane lists file servers, as Finder's does. -->
  <key>NSLocalNetworkUsageDescription</key><string>Foldera lists the file servers on your network, as Finder's Network does.</string>
  <key>NSBonjourServices</key><array><string>_smb._tcp</string><string>_afpovertcp._tcp</string></array>
  <!-- Lets macOS offer Foldera for opening folders (File › Open Folders in Foldera). -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.folder</string><string>public.volume</string></array>
    </dict>
    <!-- …for archives, which it opens like folders… -->
    <dict>
      <key>CFBundleTypeName</key><string>Archive</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.zip-archive</string><string>com.rarlab.rar-archive</string><string>org.7-zip.7-zip-archive</string><string>public.tar-archive</string><string>org.gnu.gnu-zip-tar-archive</string><string>public.archive</string></array>
    </dict>
    <!-- …and for pictures, so Foldera's viewer appears under Open With. -->
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.image</string><string>public.svg-image</string><string>com.adobe.photoshop-image</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "built $APP ($(du -sh "$APP" | cut -f1))"

if [ "$STEP" = "install" ]; then
  rm -rf "/Applications/$NAME.app"
  ditto "$APP" "/Applications/$NAME.app"
  echo "installed /Applications/$NAME.app"
fi
