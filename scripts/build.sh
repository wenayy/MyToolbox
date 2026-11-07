#!/bin/zsh
# Builds MyToolbox.app (no Xcode needed — Command Line Tools are enough).
#   ./scripts/build.sh            → build/MyToolbox.app (universal: Apple silicon + Intel)
#   ./scripts/build.sh install    → also copies to /Applications and launches it
#   ./scripts/build.sh release    → also zips it to build/MyToolbox-<version>.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/MyToolbox.app"
VERSION="1.0.1"
BUILD_NUM=$(date +%Y%m%d%H%M)

mkdir -p "$ROOT/.build"

# Command Line Tools 27 make SwiftUI's @State a macro in the macOS 27 SDK but ship its plugin only with Xcode,
# so without Xcode the build fails with "plugin for module 'SwiftUIMacros' not found". They also ship the
# macOS 26 SDK, which needs no plugin: fall back to the newest one of those.
older_sdk() {
  ls -d "$(xcode-select -p)"/SDKs/MacOSX26*.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null \
    | grep -v '/MacOSX26.sdk$' | sort -V | tail -1
}

for ARCH in arm64 x86_64; do
  echo "▸ Compiling Swift for $ARCH…"
  LOG="$ROOT/.build/release-build-$ARCH.log"
  if ! swift build -c release --arch $ARCH > "$LOG" 2>&1; then
    SDK=$(older_sdk)
    if grep -q "SwiftUIMacros" "$LOG" && [[ -n "$SDK" && -z "${SDKROOT:-}" ]]; then
      echo "  (SwiftUI macro plugin missing — building against $(basename "$SDK"))"
      export SDKROOT="$SDK"
      swift build -c release --arch $ARCH > "$LOG" 2>&1 || { grep -E "error:" "$LOG" | sort -u; echo "✗ Swift build failed — nothing installed"; exit 1; }
    else
      grep -E "error:" "$LOG" | sort -u
      echo "✗ Swift build failed — nothing installed"
      exit 1
    fi
  fi
done
BIN="$ROOT/.build/MyToolbox-universal"
lipo -create -output "$BIN" "$ROOT/.build/arm64-apple-macosx/release/MyToolbox" "$ROOT/.build/x86_64-apple-macosx/release/MyToolbox"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MyToolbox"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] || swift "$ROOT/scripts/make_icon.swift" "$ROOT/Resources" >/dev/null
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MyToolbox</string>
  <key>CFBundleDisplayName</key><string>MyToolbox</string>
  <key>CFBundleIdentifier</key><string>com.vinay.mytoolbox</string>
  <key>CFBundleExecutable</key><string>MyToolbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>MyToolbox transcribes audio and video on your Mac. Nothing is uploaded.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>macOS needs location access to tell MyToolbox the name of your current Wi-Fi network.</string>
  <key>NSLocationUsageDescription</key><string>macOS needs location access to tell MyToolbox the name of your current Wi-Fi network.</string>
  <key>NSAppleEventsUsageDescription</key><string>MyToolbox controls Keynote, Numbers, Finder and System Events only when you use a tool that needs them.</string>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Any File</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>None</string>
    <key>LSItemContentTypes</key><array><string>public.item</string><string>public.folder</string></array>
  </dict></array>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none --identifier com.vinay.mytoolbox -r='designated => identifier "com.vinay.mytoolbox"' "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ Built $APP"

if [[ "${1:-}" == "release" ]]; then
  ZIP="$ROOT/build/MyToolbox-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
  echo "✓ Release archive: $ZIP"
fi

if [[ "${1:-}" == "install" ]]; then
  echo "▸ Installing to /Applications…"
  pkill -x MyToolbox 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/MyToolbox.app
  cp -R "$APP" /Applications/
  rm -rf "$APP"
  open /Applications/MyToolbox.app
  echo "✓ Installed and launched"
fi
