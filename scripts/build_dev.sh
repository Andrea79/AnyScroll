#!/bin/bash
# Builds AnyScroll with swiftc.
#   ./scripts/build_dev.sh           -> build/dev/AnyScroll Dev.app, for testing
#   ./scripts/build_dev.sh release   -> build/release/AnyScroll.app, to install
# The two use different bundle ids, so the Dev build can run next to the
# installed app with its own settings and Accessibility permission.
set -euo pipefail

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="1.2"
if [ "${1:-}" = "release" ]; then
    APP="build/release/AnyScroll.app"
    BUNDLE_ID="io.github.andrea79.AnyScroll"
    NAME="AnyScroll"
    SHORT_VERSION="$VERSION"
    SWIFT_FLAGS=""
else
    APP="build/dev/AnyScroll Dev.app"
    BUNDLE_ID="io.github.andrea79.AnyScroll.dev"
    NAME="AnyScroll Dev"
    SHORT_VERSION="$VERSION-dev"
    SWIFT_FLAGS="-D DEBUG_LOG"   # diagnostics to ~/Library/Logs/AnyScroll Dev.log
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: one slice for Apple Silicon, one for Intel
BIN_DIR="$(mktemp -d)"
for ARCH in arm64 x86_64; do
    xcrun swiftc -O -parse-as-library $SWIFT_FLAGS \
        -target "$ARCH-apple-macos13.0" \
        -o "$BIN_DIR/AnyScroll-$ARCH" \
        AnyScroll/*.swift
done
lipo -create "$BIN_DIR/AnyScroll-arm64" "$BIN_DIR/AnyScroll-x86_64" -output "$APP/Contents/MacOS/AnyScroll"

# App icon: the asset catalog images already use iconutil's file names
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir "$ICONSET"
cp AnyScroll/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>AnyScroll</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSAccessibilityUsageDescription</key>
	<string>This app needs accessibility permissions to enable auto-scrolling with the middle mouse button.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built: $APP"
