#!/bin/zsh
# Builds a universal (arm64 + x86_64) Release Nearclip.app, signs it ad hoc, and zips it into dist/.
#   apple/scripts/build-release.sh            → dist/Nearclip-macOS.zip
# For public distribution sign with a Developer ID and notarize instead (set SIGN_IDENTITY).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)"; exit 1; }
xcodegen generate >/dev/null
xcodebuild -project Nearclip.xcodeproj -scheme Nearclip -configuration Release -derivedDataPath build/release \
  -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="$SIGN_IDENTITY" build | tail -3
APP="build/release/Build/Products/Release/Nearclip.app"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
mkdir -p "$ROOT/dist"
ditto -c -k --keepParent "$APP" "$ROOT/dist/Nearclip-macOS.zip"
lipo -archs "$APP/Contents/MacOS/Nearclip"
echo "→ $ROOT/dist/Nearclip-macOS.zip"

