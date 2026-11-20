#!/bin/sh
# Build "RGB Lock.app" and RGB-Lock.dmg into build/. Apple silicon only (connection modes are an AS feature).
set -e
cd "$(dirname "$0")"
rm -rf build
app="build/RGB Lock.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/AppIcon.iconset build/dmg

swiftc -parse-as-library -swift-version 5 -O RGBLock.swift -o "$app/Contents/MacOS/RGBLock"
cp Info.plist "$app/Contents/"

swiftc -swift-version 5 make-icon.swift -o build/make-icon
build/make-icon build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"

codesign --force --deep -s - "$app"

cp -R "$app" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "RGB Lock" -srcfolder build/dmg -format UDZO -ov build/RGB-Lock.dmg >/dev/null
echo "built: build/RGB-Lock.dmg"
