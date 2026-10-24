#!/bin/bash
# Builds the Nearclip promo film: events → score → frames (4K-class, motion blur) → mux → delivery sizes.
#   promo/make.sh [ko|en|all]          (default: all)
#   PROMO_ASPECTS="h v"                16:9 and 9:16 (default both)
#   PROMO_SAMPLES=4 PROMO_WORKERS=6    motion-blur samples per frame, parallel Chrome renderers
# Outputs per language in out/:
#   Nearclip-promo-<lang>-4k.mp4 (3840×2160) · -1080p.mp4 (1920×1080)
#   Nearclip-promo-<lang>-vertical-4k.mp4 (2160×3840) · -vertical.mp4 (1080×1920, Shorts / Reels / TikTok)
set -euo pipefail
cd "$(dirname "$0")"

LANGS="${1:-all}"
[ "$LANGS" = "all" ] && LANGS="ko en"
ASPECTS="${PROMO_ASPECTS:-h v}"
SAMPLES="${PROMO_SAMPLES:-4}"
WORKERS="${PROMO_WORKERS:-6}"

[ -d node_modules ] || npm install --silent
[ -x .venv/bin/python ] || { python3 -m venv .venv && .venv/bin/pip install -q numpy scipy pyloudnorm; }
[ -d assets/symbols ] || swift tools/export-symbols.swift assets/symbols
[ -f src/icons.js ] || node tools/make-icons.mjs
mkdir -p out

for L in $LANGS; do
  echo "▸ $L: sound"
  node render.mjs --lang "$L" --events "out/events-$L.json"
  .venv/bin/python audio/synth.py "out/events-$L.json" "out/audio-$L.wav"

  for A in $ASPECTS; do
    if [ "$A" = "v" ]; then BIG="vertical-4k"; SMALL="vertical"; SIZE="1080:1920"; else BIG="4k"; SMALL="1080p"; SIZE="1920:1080"; fi
    echo "▸ $L $A: frames ($SAMPLES samples per frame)"
    node render.mjs --lang "$L" --aspect "$A" --video "out/video-$L-$A.mp4" --dpr 2 --samples "$SAMPLES" --workers "$WORKERS"

    echo "▸ $L $A: mux"
    ffmpeg -v error -y -i "out/video-$L-$A.mp4" -i "out/audio-$L.wav" -map 0:v -map 1:a -c:v copy \
      -c:a aac -b:a 256k -ar 48000 -shortest -movflags +faststart "out/Nearclip-promo-$L-$BIG.mp4"
    ffmpeg -v error -y -i "out/Nearclip-promo-$L-$BIG.mp4" -vf "scale=$SIZE:flags=lanczos" \
      -c:v libx264 -preset slow -crf 17 -profile:v high -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
      -c:a copy -movflags +faststart "out/Nearclip-promo-$L-$SMALL.mp4"
    echo "✓ out/Nearclip-promo-$L-$BIG.mp4"
    echo "✓ out/Nearclip-promo-$L-$SMALL.mp4"
  done
done
