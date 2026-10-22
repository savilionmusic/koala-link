#!/bin/zsh
set -euo pipefail

# Builds Koala Link.app: Koala Sampler on the Akai MPC Touch. Inside:
# - the app and its icon;
# - Alicja Hand (its starting card and bank overlay);
# - the MPC Touch's touch driver v3 and tools, exactly as built and signed in outputs/ (the same files Paper Cut ships;
#   never rebuilt here, since a new build needs a new Accessibility approval);
# - the per-user install script.
# The bundle is assembled in build/.staging and swapped in at the end.
HERE="${0:A:h}"
PROJECT="$HERE"
VERSION=1.4.7
BUILD=19
cd "$HERE"
mkdir -p "$HERE/Sources/KoalaTouch/Resources/Fonts"
cp "$PROJECT/brand/font/"AlicjaHand-*.otf "$HERE/Sources/KoalaTouch/Resources/Fonts/"
mkdir -p "$HERE/.clang-cache" "$HERE/.swiftpm-cache"
CLANG_MODULE_CACHE_PATH="$HERE/.clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$HERE/.swiftpm-cache" \
  swift build --disable-sandbox -c release
BIN="$HERE/.build/release/KoalaTouch"

STAGE="$HERE/build/.staging/Koala Link.app"
rm -rf "$HERE/build/.staging"
CONTENTS="$STAGE/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Fonts" "$CONTENTS/Resources/TouchDriver"
cp "$BIN" "$CONTENTS/MacOS/KoalaTouch"
cp "$PROJECT/brand/font/"AlicjaHand-*.otf "$CONTENTS/Resources/Fonts/"
ICONSET="$HERE/build/.staging/AppIcon.iconset"
"$BIN" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$ICONSET"
DRIVER="$PROJECT/TouchDriver"
cp "$DRIVER/mpc_touchd" "$CONTENTS/Resources/TouchDriver/mpc_touchd"
for tool in mpc_replug mpc_diag mpc_watch; do cp "$DRIVER/tools/$tool" "$CONTENTS/Resources/TouchDriver/$tool"; done
cp "$HERE/installer/support/install-for-user.sh" "$CONTENTS/Resources/install-for-user.sh"
chmod 755 "$CONTENTS/Resources/install-for-user.sh" "$CONTENTS/Resources/TouchDriver/"*

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>KoalaTouch</string>
  <!-- Keep the installed identity stable across the Koala Link rename. -->
  <key>CFBundleIdentifier</key><string>com.savilion.koala-touch</string>
  <key>CFBundleName</key><string>Koala Link</string>
  <key>CFBundleDisplayName</key><string>Koala Link</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSCameraUsageDescription</key><string>Koala Link's Webcam shows and records your camera with Koala's sound.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Koala Link's Webcam records Koala's sound and lets you hear it with drive and the limiter.</string>
  <key>NSMicrophoneUsageDescription</key><string>Koala Link's Webcam records the audio input you choose.</string>
</dict></plist>
PLIST
# Sign the driver files as they are (already signed) and the app ad hoc; never re-sign mpc_touchd.
codesign --force --sign - --identifier com.savilion.koala-touch "$STAGE"
codesign --verify --strict "$STAGE"
rm -rf "$HERE/build/Koala Link.app"
mv "$STAGE" "$HERE/build/Koala Link.app"
rm -rf "$HERE/build/.staging"
echo "Built $HERE/build/Koala Link.app ($VERSION, build $BUILD)"
