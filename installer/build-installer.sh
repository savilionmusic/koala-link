#!/bin/zsh
# Builds dist/Koala-Link-Installer.pkg:
# - Koala Link.app (with its icon and the touch driver inside);
# - the touch driver, tools and uninstall script in /Library/Application Support/Koala Touch;
# - the scripts that set the driver up for the logged-in user (the same driver and LaunchAgents as Paper Cut).
# It builds; it never installs.
set -euo pipefail
HERE="${0:A:h}"
KT="${HERE:h}"
PROJECT="$KT"
DIST="$PROJECT/dist"
VERSION=1.4.5
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$KT/build-app.sh"
APP="$KT/build/Koala Link.app"

# Payload.
ROOT="$WORK/root"
SUPPORT="$ROOT/Library/Application Support/Koala Touch"
mkdir -p "$ROOT/Applications" "$SUPPORT"
ditto "$APP" "$ROOT/Applications/Koala Link.app"
ditto "$APP/Contents/Resources/TouchDriver" "$SUPPORT/TouchDriver"
cp "$HERE/support/install-for-user.sh" "$HERE/support/uninstall.sh" "$SUPPORT/"
chmod 755 "$SUPPORT/"*.sh "$SUPPORT/TouchDriver/"*
xattr -cr "$ROOT"
export COPYFILE_DISABLE=1

# The app must install to /Applications, never be "relocated" onto another copy with the same ID.
pkgbuild --analyze --root "$ROOT" "$WORK/component.plist" >/dev/null
count=$(/usr/libexec/PlistBuddy -c "Print" "$WORK/component.plist" | grep -c "BundleIsRelocatable" || true)
for (( i=0; i<count; i++ )); do /usr/libexec/PlistBuddy -c "Set :$i:BundleIsRelocatable false" "$WORK/component.plist"; done
pkgbuild --root "$ROOT" --component-plist "$WORK/component.plist" --scripts "$HERE/scripts" \
  --identifier com.savilion.koalatouch --version "$VERSION" --install-location / "$WORK/KoalaTouch.pkg" >/dev/null

# Installer window art and pages (headings in Alicja Hand, as Paper Cut's installer).
RES="$WORK/resources"
mkdir -p "$RES"
cp "$HERE/resources/"*.html "$RES/"
swiftc "$HERE/render-headings.swift" -o "$WORK/render-headings"
"$WORK/render-headings" "$PROJECT/brand/font" "$HERE/resources/headings" "$RES" >/dev/null
ditto "$HERE/resources/headings" "$RES/headings"
"$APP/Contents/MacOS/KoalaTouch" --render-installer-art "$RES"

mkdir -p "$DIST"
productbuild --distribution "$HERE/distribution.xml" --resources "$RES" --package-path "$WORK" \
  "$DIST/Koala-Link-Installer.pkg" >/dev/null
echo "Built: $DIST/Koala-Link-Installer.pkg ($(du -h "$DIST/Koala-Link-Installer.pkg" | cut -f1))"
