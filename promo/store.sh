#!/bin/bash
# Microsoft Store listing assets for Nearclip (the Windows listing), made from the launch film.
#   promo/store.sh                  screenshots, art and trailers
#   promo/store.sh art trailer      only some of them (shots · art · trailer)
#   STORE_LANGS=en promo/store.sh   one language (default: en ko)
# Outputs in out/store/:
#   screenshots/<lang>/01-…07-….png   desktop screenshots, 3840×2160, in listing order (moments of the film, held still,
#                                     captions included, plus the Windows flyout drawn large)
#   art/                              StoreLogo 300×300 · box art 1:1 · poster art 2:3 · super hero art 16:9 (store.html)
#   trailer/                          Nearclip-trailer-<lang>.mp4 (the film, encoded for the Store) and its 1920×1080 thumbnail
# Render the film first (promo/make.sh): the trailers are encoded from its 4K masters and WAV scores.
set -euo pipefail
cd "$(dirname "$0")"

PARTS="${*:-shots art trailer}"
LANGS="${STORE_LANGS:-en ko}"
OUT=out/store
# Seconds into the film : file name. "windows" is the flyout close-up made with store.html from a 4× still of the apps.
SHOTS="25.2:01-one-clipboard 8.4:02-mac-to-windows 19.4:03-iphone-to-windows windows:04-windows-flyout 27.4:05-pair-with-qr 29.6:06-another-network 31.6:07-end-to-end"

[ -d node_modules ] || npm install --silent
flat() { magick "$1" -alpha off -define png:color-type=2 "$2"; }

for part in $PARTS; do
  case $part in
    shots)
      for L in $LANGS; do
        times=""
        for s in $SHOTS; do t="${s%%:*}"; [ "$t" = windows ] || times="$times,$t"; done
        node render.mjs --stills "${times#,}" --lang "$L" --dpr 2 >/dev/null
        node render.mjs --stills 25.2 --lang "$L" --dpr 4 --dir out/stills4 >/dev/null
        mkdir -p "$OUT/screenshots/$L" out/store/work
        # The Windows device from the four-apps moment (the dpr-2 crop in website/tools/media.sh, doubled).
        magick "out/stills4/$L-25.20.png" -crop 1740x2540+2600+1132 +repage "out/store/work/windows-$L.png"
        for s in $SHOTS; do
          t="${s%%:*}"; name="${s#*:}"
          if [ "$t" = windows ]; then
            node store.mjs "shot=windows&lang=$L&img=out/store/work/windows-$L.png" "out/store/work/$name-$L.png" 1920 1080 2 >/dev/null
            flat "out/store/work/$name-$L.png" "$OUT/screenshots/$L/$name.png"
          else
            flat "out/stills/$L-$(printf '%.2f' "$t").png" "$OUT/screenshots/$L/$name.png"
          fi
        done
        echo "✓ $OUT/screenshots/$L"
      done
      ;;
    art)
      mkdir -p "$OUT/art"
      shot() { node store.mjs "$1" "$OUT/art/$5" "$2" "$3" "$4" >/dev/null; flat "$OUT/art/$5" "$OUT/art/$5"; echo "✓ $OUT/art/$5"; }
      shot art=hero 1920 1080 2 SuperHeroArt-3840x2160.png
      shot art=hero 1920 1080 1 SuperHeroArt-1920x1080.png
      shot art=box 1080 1080 2 BoxArt-2160x2160.png
      shot art=box 1080 1080 1 BoxArt-1080x1080.png
      shot art=poster 720 1080 2 PosterArt-1440x2160.png
      shot art=poster 720 1080 1 PosterArt-720x1080.png
      # The app tile icon is the Windows icon itself (design/out/icon-windows.svg), transparent corners included.
      (cd ../design && node -e 'require("sharp")("out/icon-windows.svg", { density: 300 }).resize(300, 300).png().toFile("../promo/" + process.argv[1])' "$OUT/art/StoreLogo-300x300.png")
      echo "✓ $OUT/art/StoreLogo-300x300.png"
      ;;
    trailer)
      mkdir -p "$OUT/trailer"
      log=$(mktemp -d)
      for L in $LANGS; do
        # Microsoft's trailer recommendations: H.264 High, progressive 4:2:0, two consecutive B-frames, a closed GOP of half
        # the frame rate (60 fps → 30 frames), CABAC, at most 50 Mbps (two passes at 14); AAC-LC, 48 kHz stereo, 384 kbps;
        # no metadata, no edit lists, the index up front. The 4K master and the WAV score save one generation of loss.
        # setparams tags the frames BT.709 (this ffmpeg drops -color_primaries/-color_trc on filtered frames otherwise).
        V=(-vf "scale=1920:1080:flags=lanczos,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv"
          -c:v libx264 -preset slow -profile:v high -level:v 4.2 -pix_fmt yuv420p
          -b:v 14M -maxrate 16M -bufsize 32M -flags +cgop -passlogfile "$log/$L"
          -x264-params "bframes=2:b-adapt=0:b-pyramid=none:keyint=30:min-keyint=30:scenecut=0:open-gop=0:cabac=1"
          -color_primaries bt709 -color_trc bt709 -colorspace bt709)
        ffmpeg -v error -y -i "out/Nearclip-promo-$L-4k.mp4" -map 0:v:0 "${V[@]}" -pass 1 -an -f null /dev/null
        ffmpeg -v error -y -i "out/Nearclip-promo-$L-4k.mp4" -i "out/audio-$L.wav" -map 0:v:0 -map 1:a:0 "${V[@]}" -pass 2 \
          -c:a aac -profile:a aac_low -b:a 384k -ar 48000 -ac 2 -shortest \
          -map_metadata -1 -map_chapters -1 -use_editlist 0 -movflags +faststart "$OUT/trailer/Nearclip-trailer-$L.mp4"
        node store.mjs "art=thumb&lang=$L" "$OUT/trailer/Nearclip-trailer-$L-thumbnail.png" 1920 1080 1 >/dev/null
        flat "$OUT/trailer/Nearclip-trailer-$L-thumbnail.png" "$OUT/trailer/Nearclip-trailer-$L-thumbnail.png"
        echo "✓ $OUT/trailer/Nearclip-trailer-$L.mp4"
      done
      ;;
  esac
done

