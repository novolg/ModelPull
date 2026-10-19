#!/bin/zsh
# Build release binary and wrap it into build/ModelPull.app (ad-hoc signed).
set -euo pipefail
cd "${0:a:h}/.."

swift build -c release --product ModelPullApp

APP=${APP:-build/ModelPull.app}   # APP=dist/macos/ModelPull.app for a release build next to a running copy
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ModelPullApp "$APP/Contents/MacOS/ModelPull"
[ -f build/icons/AppIcon.icns ] || { swift scripts/make-icons.swift resources/modelpull-logo.png &&iconutil -c icns build/icons/AppIcon.iconset -o build/icons/AppIcon.icns; }
cp build/icons/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ModelPull</string>
  <key>CFBundleDisplayName</key><string>ModelPull</string>
  <key>CFBundleIdentifier</key><string>io.github.novolg.modelpull</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ModelPull</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"
