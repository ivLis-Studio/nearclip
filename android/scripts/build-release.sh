#!/bin/zsh
# Builds the R8-minified release APK and signs it with the release key into dist/Nearclip-Android.apk.
#   NEARCLIP_KEYSTORE=/path/to/nearclip-release.jks android/scripts/build-release.sh
# The keystore password comes from NEARCLIP_KEYSTORE_PASS, or else from the login keychain item
# "Nearclip Android release key" (security add-generic-password -s "Nearclip Android release key" -a nearclip -w).
# The key alias is "nearclip". Keep the keystore backed up: every update must be signed with the same key.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
KS="${NEARCLIP_KEYSTORE:?set NEARCLIP_KEYSTORE to the release keystore}"
PASS="${NEARCLIP_KEYSTORE_PASS:-$(security find-generic-password -s 'Nearclip Android release key' -a nearclip -w)}"
SDK="$(sed -n 's/^sdk.dir=//p' local.properties)"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
./gradlew -q :app:assembleRelease
IN=app/build/outputs/apk/release/app-release-unsigned.apk
TMP="$(mktemp -d)"
"$BT/zipalign" -p -f 4 "$IN" "$TMP/aligned.apk"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/Nearclip-Android.apk"
NEARCLIP_KS_PASS="$PASS" "$BT/apksigner" sign --ks "$KS" --ks-key-alias nearclip --ks-pass env:NEARCLIP_KS_PASS --out "$OUT" "$TMP/aligned.apk"
"$BT/apksigner" verify --verbose --print-certs "$OUT" | grep -E 'Verified using|Signer #1 certificate (DN|SHA-256)'
echo "→ $OUT"

