#!/bin/zsh
# Builds a universal (arm64 + x86_64) Release Nearclip.app and zips it into dist/Nearclip-macOS.zip.
#   apple/scripts/build-release.sh                                   signed ad hoc (local use)
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<profile> apple/scripts/build-release.sh
#                                                                    Developer ID + hardened runtime, notarized, stapled
# NOTARY_PROFILE is an `xcrun notarytool store-credentials` keychain profile.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)"; exit 1; }
xcodegen generate >/dev/null
xcodebuild -project Nearclip.xcodeproj -scheme Nearclip -configuration Release -derivedDataPath build/release \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" build | tail -3
APP="build/release/Build/Products/Release/Nearclip.app"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/Nearclip-macOS.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP"
fi
lipo -archs "$APP/Contents/MacOS/Nearclip"
echo "→ $ZIP"

