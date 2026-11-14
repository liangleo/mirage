#!/usr/bin/env bash
# Build a local, ad-hoc signed Mirage.app with the menu bar app and helper.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$ROOT" && swift tools/make_icon.swift >/dev/null)
cd "$ROOT/mac"

BIN="$(swift build -c release --product mirage-menu --show-bin-path)"
swift build -c release --product mirage-helper
swift build -c release --product mirage-menu

APP="$ROOT/build/.Mirage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Keep the dev bundle out of Spotlight so only the installed app is searchable.
touch "$ROOT/build/.metadata_never_index"

cp "$BIN/mirage-menu" "$APP/Contents/MacOS/Mirage"
cp "$BIN/mirage-helper" "$APP/Contents/MacOS/mirage-helper"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Mirage</string>
    <key>CFBundleIdentifier</key>
    <string>app.mirage.menu</string>
    <key>CFBundleName</key>
    <string>Mirage</string>
    <key>CFBundleDisplayName</key>
    <string>Mirage</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null

echo "built $APP"
echo "open \"$APP\"   # or: open \"$APP\" --args --autostart extend"