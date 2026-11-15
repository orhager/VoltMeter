#!/bin/zsh
# Builds VoltMeter.app next to this script. `zsh build.sh install` also copies it to /Applications.
set -e
cd "$(dirname "$0")"
APP=VoltMeter.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
[ -f AppIcon.icns ] || { swift icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns; }
cp AppIcon.icns $APP/Contents/Resources/
swiftc -O -parse-as-library VoltMeter.swift -o $APP/Contents/MacOS/VoltMeter \
  -framework SwiftUI -framework AVFoundation -framework CoreAudio -framework IOKit
cat > $APP/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.orhager.voltmeter</string>
  <key>CFBundleName</key><string>VoltMeter</string>
  <key>CFBundleExecutable</key><string>VoltMeter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>VoltMeter reads the Volt 2 inputs to show levels.</string>
</dict></plist>
EOF
# Sign with the Apple Development certificate when there is one. A stable identity
# keeps macOS's microphone permission across rebuilds; ad-hoc signing (the fallback)
# looks like a new app every time and asks again.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" $APP
else
  echo "no Apple Development certificate, signing ad-hoc (microphone access will be asked again)"
  codesign --force --sign - $APP
fi
if [ "$1" = "install" ]; then
  pkill -x VoltMeter 2>/dev/null || true; sleep 0.5
  rm -rf /Applications/VoltMeter.app && cp -R $APP /Applications/ && echo "installed /Applications/VoltMeter.app"
fi
echo "built $PWD/$APP"
