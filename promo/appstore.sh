#!/bin/bash
# App Store screenshots for Nearclip (iOS, iPadOS and macOS), framed by appstore.html from real screenshots of the apps.
#   promo/appstore.sh              everything (en and ko)
#   STORE_LANGS=en promo/appstore.sh
# The raw screenshots come first (both drive the real apps against CLI peers that stand in for the other devices):
#   python3 apple/tools/appstore_shots.py --device iphone|ipad --lang en|ko --out promo/out/appstore/raw/<device>-<lang>
#   python3 apple/tools/appstore_mac_shots.py --lang en|ko --out promo/out/appstore/raw/mac-<lang>
# The Mac set also uses three held moments of the film (promo/store.sh shots).
# Outputs in out/appstore/<lang>/: iphone-1…4.png (1320×2868, 6.9"), iphone63-1…4.png (1206×2622, 6.3", the size
# App Store Connect requires), ipad-1…4.png (2064×2752, 13"), mac-1…6.png (2880×1800). App Store Connect scales them
# down for the smaller sizes.
set -euo pipefail
cd "$(dirname "$0")"
LANGS="${STORE_LANGS:-en ko}"
[ -d node_modules ] || npm install --silent
jobs="["
for L in $LANGS; do
  mkdir -p "out/appstore/$L"
  for n in 1 2 3 4; do jobs+="{\"query\":\"dev=iphone&lang=$L&n=$n\",\"out\":\"out/appstore/$L/iphone-$n.png\",\"w\":1320,\"h\":2868},"; done
  for n in 1 2 3 4; do jobs+="{\"query\":\"dev=iphone&lang=$L&n=$n\",\"out\":\"out/appstore/$L/iphone63-$n.png\",\"w\":1206,\"h\":2622},"; done
  for n in 1 2 3 4; do jobs+="{\"query\":\"dev=ipad&lang=$L&n=$n\",\"out\":\"out/appstore/$L/ipad-$n.png\",\"w\":2064,\"h\":2752},"; done
  for n in 1 2 3 4 5 6; do jobs+="{\"query\":\"dev=mac&lang=$L&n=$n\",\"out\":\"out/appstore/$L/mac-$n.png\",\"w\":2880,\"h\":1800},"; done
done
jobs="${jobs%,}]"
node appstore.mjs "$jobs" >/dev/null
# App Store Connect rejects screenshots with an alpha channel.
for f in out/appstore/*/*.png; do magick "$f" -alpha off -define png:color-type=2 "$f"; done
for L in $LANGS; do echo "✓ out/appstore/$L ($(ls "out/appstore/$L" | wc -l | tr -d ' ') screenshots)"; done

