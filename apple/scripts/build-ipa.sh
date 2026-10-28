#!/bin/zsh
# Packages the iPhone and iPad app as dist/Nearclip-iOS.ipa, for sideloading with AltStore or SideStore.
#   apple/scripts/build-ipa.sh                          archives NearclipiOS (Release, unsigned) first
#   apple/scripts/build-ipa.sh <NearclipiOS.xcarchive>  repackages an existing archive, such as the App Store one
# The IPA is signed ad hoc without provisioning profiles. The share extension keeps its shared keychain
# entitlement; AltStore and SideStore rewrite the signing prefix for the installer's own Apple ID.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
WORK="$(mktemp -d)"
ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
  command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)"; exit 1; }
  xcodegen generate >/dev/null
  ARCHIVE="$WORK/Nearclip.xcarchive"
  xcodebuild -project Nearclip.xcodeproj -scheme NearclipiOS -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath build/ipa -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO archive | tail -3
fi
[ -d "$ARCHIVE/Products/Applications/Nearclip.app" ] || { echo "no Nearclip.app in $ARCHIVE"; exit 1; }
APP="$WORK/Payload/Nearclip.app"
mkdir -p "$WORK/Payload" "$WORK/left-out" "$ROOT/dist"
ditto --norsrc --noextattr "$ARCHIVE/Products/Applications/Nearclip.app" "$APP"
# A development or App Store profile names the team and its devices: it stays out of the IPA.
[ ! -e "$APP/embedded.mobileprovision" ] || mv "$APP/embedded.mobileprovision" "$WORK/left-out/main.mobileprovision"
if [ -d "$APP/PlugIns/NearclipShare.appex" ]; then
  # An unsigned archive has no embedded entitlements; supply the shared keychain group explicitly.
  # The sideload signer replaces this original build-team prefix when signing the app and its extension.
  SIDeloadEntitlements="$WORK/sideload.entitlements"
  sed 's/$(AppIdentifierPrefix)/7NT8ZLSW2P./g' iOS/Nearclip.entitlements > "$SIDeloadEntitlements"
  for extension in "$APP"/PlugIns/*.appex; do
    [ ! -e "$extension/embedded.mobileprovision" ] || mv "$extension/embedded.mobileprovision" "$WORK/left-out/$(basename "$extension").mobileprovision"
    codesign --force --sign - --entitlements "$SIDeloadEntitlements" "$extension"
  done
  codesign --force --sign - --entitlements "$SIDeloadEntitlements" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
(cd "$WORK" && zip -qry -X Nearclip-iOS.ipa Payload)
mv -f "$WORK/Nearclip-iOS.ipa" "$ROOT/dist/Nearclip-iOS.ipa"
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Info.plist"; }
echo "Nearclip $(plist CFBundleShortVersionString) ($(plist CFBundleVersion)) · iOS $(plist MinimumOSVersion)+ · $(lipo -archs "$APP/Nearclip")"
echo "→ $ROOT/dist/Nearclip-iOS.ipa"
