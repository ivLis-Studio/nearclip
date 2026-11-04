#!/bin/bash
# App Store screenshots for Nearclip (iOS, iPadOS and macOS), framed by appstore.html from real screenshots of the apps.
#   promo/appstore.sh              everything (en and ko)
#   STORE_LANGS=en promo/appstore.sh
# The raw screenshots come first (both drive the real apps against CLI peers that stand in for the other devices):
#   python3 apple/tools/appstore_shots.py --device iphone|ipad --lang en|ko --out promo/out/appstore/raw/<device>-<lang>
#   python3 apple/tools/appstore_mac_shots.py --lang en|ko --out promo/out/appstore/raw/apple-mac-<lang>
# Apple-specific captions and native Mac captures are used; cross-platform launch-film frames are excluded.
# Outputs in out/appstore/apple/<lang>/: two screenshots each for iPhone 6.9", iPhone 6.3", iPad 13" and Mac.
# STORE_OUTPUT can select another output directory. Keep this set separate from legacy cross-platform assets.
set -euo pipefail
cd "$(dirname "$0")"
LANGS="${STORE_LANGS:-en ko}"
OUTPUT="${STORE_OUTPUT:-out/appstore/apple}"
[ -d node_modules ] || npm install --silent
jobs="["
for L in $LANGS; do
  mkdir -p "$OUTPUT/$L"
  for n in 1 2; do jobs+="{\"query\":\"dev=iphone&lang=$L&n=$n\",\"out\":\"$OUTPUT/$L/iphone-$n.png\",\"w\":1320,\"h\":2868},"; done
  for n in 1 2; do jobs+="{\"query\":\"dev=iphone&lang=$L&n=$n\",\"out\":\"$OUTPUT/$L/iphone63-$n.png\",\"w\":1206,\"h\":2622},"; done
  for n in 1 2; do jobs+="{\"query\":\"dev=ipad&lang=$L&n=$n\",\"out\":\"$OUTPUT/$L/ipad-$n.png\",\"w\":2064,\"h\":2752},"; done
  for n in 1 2; do jobs+="{\"query\":\"dev=mac&lang=$L&n=$n\",\"out\":\"$OUTPUT/$L/mac-$n.png\",\"w\":2880,\"h\":1800},"; done
done
jobs="${jobs%,}]"
node appstore.mjs "$jobs" >/dev/null
# App Store Connect rejects screenshots with an alpha channel.
for L in $LANGS; do
  for f in "$OUTPUT/$L"/*.png; do magick "$f" -alpha off -define png:color-type=2 "$f"; done
done
for L in $LANGS; do echo "✓ $OUTPUT/$L ($(ls "$OUTPUT/$L" | wc -l | tr -d ' ') screenshots)"; done

