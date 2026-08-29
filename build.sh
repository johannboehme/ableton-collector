#!/bin/bash
# Baut "Ableton Collector.app" als Universal Binary (Apple Silicon + Intel)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Ableton Collector"
BUILD=build
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "→ Kompiliere (arm64) …"
swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  Sources/CollectorCore.swift Sources/App.swift \
  -o "$BUILD/AbletonCollector-arm64"

echo "→ Kompiliere (x86_64) …"
swiftc -O -parse-as-library \
  -target x86_64-apple-macos13.0 \
  Sources/CollectorCore.swift Sources/App.swift \
  -o "$BUILD/AbletonCollector-x86_64"

echo "→ Universal Binary …"
lipo -create "$BUILD/AbletonCollector-arm64" "$BUILD/AbletonCollector-x86_64" \
  -output "$BUILD/AbletonCollector"

echo "→ App-Icon …"
swift Resources/make_icon.swift "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"

echo "→ App-Bundle …"
APP="$BUILD/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/AbletonCollector" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/"

echo "→ Signiere (ad-hoc) …"
codesign --force --deep -s - "$APP"

echo "→ Zip fuer die Weitergabe …"
ditto -c -k --keepParent "$APP" "$BUILD/AbletonCollector.zip"

echo
echo "Fertig: $APP"
echo "Zip:    $BUILD/AbletonCollector.zip"
