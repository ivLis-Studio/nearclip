#!/bin/zsh
# Builds public/assets/media from promo/ and design/: the film (16:9 and 9:16, Korean and English) with posters, stills of
# the film for the page, the icons and the social card. Needs ffmpeg, ImageMagick 7 (magick) and Google Chrome.
#   promo/make.sh               # renders the film into promo/out (once)
#   website/tools/media.sh      # then this
set -euo pipefail
cd "$(dirname "$0")/.."
SITE="$PWD"
ROOT="$(cd .. && pwd)"
OUT="$SITE/public/assets/media"
STILLS="$SITE/.stills"
mkdir -p "$OUT" "$STILLS"
webp() { magick "$1" "${@:3}" -quality "${Q:-82}" -define webp:method=6 "$2"; }

# 1. The film: the promo's 1080p and vertical cuts, remuxed so playback starts before the whole file is in.
for l in ko en; do
  ffmpeg -loglevel error -y -i "$ROOT/promo/out/Nearclip-promo-$l-1080p.mp4" -c copy -movflags +faststart "$OUT/film-$l.mp4"
  ffmpeg -loglevel error -y -i "$ROOT/promo/out/Nearclip-promo-$l-vertical.mp4" -c copy -movflags +faststart "$OUT/film-$l-v.mp4"
done

# 2. Stills of the film at 2× (the renderer draws any moment exactly): three demos, the four apps and the end card.
( cd "$ROOT/promo"
  for l in ko en; do
    node render.mjs --stills 8.4,14.4,19.4,25.2,38.0 --lang "$l" --dpr 2 --dir ../website/.stills >/dev/null
    node render.mjs --stills 38.0 --lang "$l" --aspect v --dir ../website/.stills >/dev/null
  done )

for l in ko en; do
  webp "$STILLS/$l-38.00.png" "$OUT/poster-$l.webp" -resize 1920x1080
  webp "$STILLS/$l-v-38.00.png" "$OUT/poster-$l-v.webp"
  # The demos without their captions (the page has its own words).
  i=1
  for t in 8.40 14.40 19.40; do
    Q=80 webp "$STILLS/$l-$t.png" "$OUT/pair-$i-$l.webp" -crop 3840x1564+0+446 +repage -resize 2400x
    i=$((i + 1))
  done
  # The same history in the four apps, one device each.
  Q=86 webp "$STILLS/$l-25.20.png" "$OUT/app-mac-$l.webp" -crop 912x1270+330+566 +repage -resize x940
  Q=86 webp "$STILLS/$l-25.20.png" "$OUT/app-win-$l.webp" -crop 870x1270+1300+566 +repage -resize x940
  Q=86 webp "$STILLS/$l-25.20.png" "$OUT/app-android-$l.webp" -crop 604x1270+2228+566 +repage -resize x940
  Q=86 webp "$STILLS/$l-25.20.png" "$OUT/app-ios-$l.webp" -crop 620x1270+2888+566 +repage -resize x940
done

# 3. Social card (1200×630) from the English end card.
magick "$STILLS/en-38.00.png" -crop 3840x2016+0+72 +repage -resize 1200x630 -strip "$OUT/og-en.png"

# 4. Icons and the photo the demo copies.
magick "$ROOT/design/out/nearclip-512.png" -strip "$OUT/icon-512.png"
magick "$ROOT/design/out/nearclip-512.png" -resize 64x64 -strip "$OUT/favicon-64.png"
magick "$ROOT/design/out/ios-1024.png" -resize 180x180 -strip "$OUT/apple-touch-icon.png"
cp "$ROOT/design/out/glyph-white.svg" "$OUT/glyph.svg"
Q=80 webp "$ROOT/promo/assets/lisbon.jpg" "$OUT/lisbon.webp" -resize 320x320^ -gravity center -extent 320x320
ls -la "$OUT"

