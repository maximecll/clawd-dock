#!/bin/bash
# Build Clawd Dock and assemble the .app bundle (no Xcode required).
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Clawd Dock.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
    -target arm64-apple-macos13.0 \
    -framework AppKit \
    -o "$APP/Contents/MacOS/ClawdDock" \
    Sources/Hooks.swift Sources/PetView.swift Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Clawd Dock</string>
    <key>CFBundleDisplayName</key><string>Clawd Dock</string>
    <key>CFBundleExecutable</key><string>ClawdDock</string>
    <key>CFBundleIdentifier</key><string>local.clawd.dockpet</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: avoids local Gatekeeper warnings
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "✅ Built: $APP"
