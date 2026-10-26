#!/bin/bash
# Builds a universal (Apple Silicon + Intel) "GoPro Timelapser.app" and zips it.
# Needs Xcode (or its command line tools) on macOS. Output: mac/build/
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
APP_NAME="GoPro Timelapser"
APP="build/$APP_NAME.app"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GoProTimelapser" "$APP/Contents/MacOS/GoProTimelapser"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>io.github.tomjxyz.goprotimelapser</string>
  <key>CFBundleExecutable</key><string>GoProTimelapser</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.movie</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature: required for Apple Silicon to run it at all. Not notarized.
codesign --force --deep --sign - "$APP"

echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/GoProTimelapser")"
for arch in x86_64 arm64; do
  echo -n "$arch minimum macOS: "
  vtool -arch "$arch" -show-build "$APP/Contents/MacOS/GoProTimelapser" | awk '/minos/ {print $2}'
done

ditto -c -k --keepParent "$APP" "build/GoPro-Timelapser-mac.zip"
echo "Built mac/build/GoPro-Timelapser-mac.zip"
