#!/bin/bash
# Builds build/Foldera.app around the SwiftPM binary, ad-hoc signed so it
# runs on this Mac.
#
#   ./build.sh            release build → build/Foldera.app
#   ./build.sh debug      debug build, same place
#   ./build.sh install    release build, then copied to /Applications
#   ./build.sh dmg        release build, then build/Foldera-<version>.dmg to hand out
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

if [ "$STEP" = "dmg" ]; then
  # The usual Mac disk image: Foldera beside a link to Applications, over a
  # background with an arrow, so installing is one drag.
  DMG="build/$NAME-$VERSION${STAGE:+-$STAGE}.dmg"
  STAGING="build/dmg"
  rm -rf "$STAGING" "$DMG" build/rw.dmg
  mkdir -p "$STAGING/.background"
  ditto "$APP" "$STAGING/$NAME.app"
  ln -s /Applications "$STAGING/Applications"
  swift Icon/dmg-background.swift "$STAGING/.background"
  hdiutil create -quiet -ov -srcfolder "$STAGING" -volname "$NAME" -fs HFS+ -format UDRW build/rw.dmg
  MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen build/rw.dmg | awk -F'\t' '/\/Volumes\//{print $NF}')"
  # Finder lays out the window and remembers it in the image. It needs
  # permission to be scripted; without it the image still works, unarranged.
  # Set FOLDERA_DMG_LAYOUT=0 for headless builds or unavailable Finder automation.
  if [ "${FOLDERA_DMG_LAYOUT:-1}" != "0" ]; then
  osascript - "$(basename "$MOUNT")" "$NAME.app" <<'APPLESCRIPT' || echo "(Finder layout skipped)"
on run argv
  with timeout of 15 seconds
  tell application "Finder"
    tell disk (item 1 of argv)
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {200, 120, 860, 520}
      set options to the icon view options of container window
      set arrangement of options to not arranged
      set icon size of options to 128
      set text size of options to 13
      set background picture of options to file ".background:background.tiff"
      set position of item (item 2 of argv) of container window to {165, 185}
      set position of item "Applications" of container window to {495, 185}
      update without registering applications
      delay 1
      close
    end tell
  end tell
  end timeout
end run
APPLESCRIPT
  fi
  # The disk shows Foldera's icon while it is open. (After the layout:
  # Finder drops the icon file when it arranges the window.)
  cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
  SetFile -a C "$MOUNT" 2>/dev/null || true
  sync
  hdiutil detach -quiet "$MOUNT"
  hdiutil convert -quiet build/rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG"
  rm -rf build/rw.dmg "$STAGING"
  echo "built $DMG ($(du -h "$DMG" | cut -f1))"
fi
