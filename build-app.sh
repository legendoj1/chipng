#!/bin/zsh
# Builds Chipng.app.
#   ./build-app.sh            → build/Chipng.app (for testing)
#   ./build-app.sh --install  → /Applications/Chipng.app only
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
# SwiftPM's build database doesn't work on Google Drive / network volumes,
# so build products live in a local cache folder.
WORK="$HOME/Library/Caches/Chipng-build"
APP="$WORK/Chipng.app"
VERSION="1.0"

echo "→ Compiling"
swift build -c release --scratch-path "$WORK" --package-path "$ROOT"

echo "→ Assembling Chipng.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/release/Chipng" "$APP/Contents/MacOS/Chipng"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
ditto "$ROOT/Resources/Squoosh" "$APP/Contents/Resources/Squoosh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Chipng</string>
  <key>CFBundleDisplayName</key><string>Chipng</string>
  <key>CFBundleIdentifier</key><string>com.chipng.mac</string>
  <key>CFBundleExecutable</key><string>Chipng</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Alpha bleeding from chipng · Compression by Squoosh</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PNG Image</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.png</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "→ Signing (ad hoc)"
codesign --force --deep --sign - "$APP"

# Only one finished copy is kept, so Spotlight doesn't list Chipng twice.
rm -rf "$ROOT/build/Chipng.app"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Chipng.app
  ditto --norsrc "$APP" /Applications/Chipng.app
  echo "✓ Installed to /Applications/Chipng.app"
else
  mkdir -p "$ROOT/build"
  ditto --norsrc "$APP" "$ROOT/build/Chipng.app"
  echo "✓ $ROOT/build/Chipng.app"
fi
