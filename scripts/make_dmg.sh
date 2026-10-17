#!/bin/bash
# Packs build/release/AnyScroll.app for a release:
#   build/release/AnyScroll-<version>.dmg  the app next to an Applications shortcut,
#                                          with the AnyScroll volume icon
#   build/release/AnyScroll-<version>.zip  the app alone
# Extended attributes (Finder and provenance tags of this Mac) are left out.
# Run ./scripts/build_dev.sh release first.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP="build/release/AnyScroll.app"
[ -d "$APP" ] || { echo "Build the app first: ./scripts/build_dev.sh release" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="AnyScroll $VERSION"
DMG="build/release/AnyScroll-$VERSION.dmg"
ZIP="build/release/AnyScroll-$VERSION.zip"

WORK="$(mktemp -d)"
trap 'hdiutil detach -quiet "$WORK/mount" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Contents: the app and a shortcut to drag it onto
mkdir "$WORK/content"
ditto --noextattr --noqtn "$APP" "$WORK/content/AnyScroll.app"
xattr -cr "$WORK/content/AnyScroll.app"
ln -s /Applications "$WORK/content/Applications"

# Writable image first, to give the volume its icon, then compress it
hdiutil create -quiet -volname "$NAME" -srcfolder "$WORK/content" -fs HFS+ -format UDRW "$WORK/rw.dmg"
mkdir "$WORK/mount"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$WORK/mount" "$WORK/rw.dmg"
cp "$APP/Contents/Resources/AppIcon.icns" "$WORK/mount/.VolumeIcon.icns"
# Files written into the image get this Mac's tags again; keep only the custom-icon flag
xattr -cr "$WORK/mount/AnyScroll.app" "$WORK/mount/.VolumeIcon.icns"
xattr -d com.apple.provenance "$WORK/mount" 2>/dev/null || true
xcrun SetFile -a C "$WORK/mount"
hdiutil detach -quiet "$WORK/mount"

rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
# Zip of the same clean copy, without the __MACOSX attribute folder
rm -f "$ZIP"
(cd "$WORK/content" && ditto -c -k --norsrc --noextattr --keepParent AnyScroll.app "$OLDPWD/$ZIP")

echo "Built: $DMG"
echo "Built: $ZIP"
shasum -a 256 "$DMG" "$ZIP"
