#!/bin/bash
# Packs build/release/AnyScroll.app into build/release/AnyScroll-<version>.dmg:
# the app next to an Applications shortcut, with the AnyScroll volume icon.
# Run ./scripts/build_dev.sh release first.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP="build/release/AnyScroll.app"
[ -d "$APP" ] || { echo "Build the app first: ./scripts/build_dev.sh release" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="AnyScroll $VERSION"
DMG="build/release/AnyScroll-$VERSION.dmg"

WORK="$(mktemp -d)"
trap 'hdiutil detach -quiet "$WORK/mount" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Contents: the app and a shortcut to drag it onto
mkdir "$WORK/content"
ditto "$APP" "$WORK/content/AnyScroll.app"
ln -s /Applications "$WORK/content/Applications"

# Writable image first, to give the volume its icon, then compress it
hdiutil create -quiet -volname "$NAME" -srcfolder "$WORK/content" -fs HFS+ -format UDRW "$WORK/rw.dmg"
mkdir "$WORK/mount"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$WORK/mount" "$WORK/rw.dmg"
cp "$APP/Contents/Resources/AppIcon.icns" "$WORK/mount/.VolumeIcon.icns"
xcrun SetFile -a C "$WORK/mount"
hdiutil detach -quiet "$WORK/mount"

rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
echo "Built: $DMG"
shasum -a 256 "$DMG"
