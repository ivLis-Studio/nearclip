# Nearclip promo film

A 39-second launch film rendered entirely from code — the stage, the motion and the sound — in 16:9 and 9:16, in
Korean and English. The point it makes is the product's: one clipboard across Mac, Windows, Android and iPhone.

```bash
promo/make.sh                         # Korean and English, 16:9 and 9:16
promo/make.sh ko                      # one language
PROMO_ASPECTS=v promo/make.sh en      # only the vertical cut
```

Outputs land in `promo/out/`, all 60 fps with AAC 256 kb/s audio:

- `Nearclip-promo-<lang>-4k.mp4` (3840×2160) and `-1080p.mp4`
- `Nearclip-promo-<lang>-vertical-4k.mp4` (2160×3840) and `-vertical.mp4` (1080×1920) for Shorts, Reels and TikTok.
  The vertical cut has its own layouts: captions sit below the top 190 px and nothing that has to be read goes in the
  bottom 400 px, where the platforms draw their own buttons.

## The edit

One beat grid (120 BPM, a bar is 2 s, `window.MUSIC`) is shared by the cuts and the score. Flat colour only — Iris
(`#4C5BF5`), ink and paper — real UI rebuilt from the four apps, no gradients or glows.

| Beats | Scene |
| --- | --- |
| 0–8 | Hook on Iris: "[Mac]에서 복사하고, [iPhone]에서 붙여넣기." — the platform names roll, then the camera pulls back out of the Mac's wallpaper |
| 8–17 | Mac → iPhone: select an address in a note, ⌘C, the clip flies into the iPhone's history |
| 18–29 | Android → Windows (colour wipe): "Send to my devices" on a sign-in code, Ctrl+V fills the code on the PC |
| 30–39 | iPhone → Mac: the Paste button sends a photo, ⌘V drops it into a note |
| 40–51 | All four: the same history in the macOS panel, the Windows flyout and the Android and iOS apps; a clip copied on Windows ripples into the other three |
| 52–67 | Four cards, one bar each, on the drop: QR pairing · another network (remote connection) · end-to-end encryption · one history (search, pin) |
| 67–78 | The last card folds into the app icon: name, "여기서 복사하고, 저기서 붙여넣기.", the four platforms, by ivLis STUDIO |

## How it works

- `index.html` + `src/` draw the stage; `renderAt(t)` is a pure function of time, so every frame is reproducible.
  `src/devices.js` draws the flat MacBook, monitor, Pixel and iPhone; `src/apps.js` rebuilds Nearclip's own UI on each
  platform from the apps (`apple/macOS/HistoryView.swift`, `apple/iOS/HomeView.swift`, `android/.../ui/home`,
  `windows/.../Views/FlyoutWindow.xaml`) with their real strings; `src/extras.js` has the apps around it (a note,
  a sign-in page, a text message) and the keycaps, pointers, touches and the travelling clip; `src/scene-a.js` builds
  the hook and the three demos, `src/scene-b.js` the four-platform grid, the cards, the end card and the timeline.
- `render.mjs` drives headless Chrome, averages sub-frames for motion blur and encodes chunks in parallel. The stage
  records its own sound cues (`window.AUDIO_EVENTS`) from the timeline constants.
- `audio/synth.py` writes the score and every sound effect from scratch (no samples): F major, a Rhodes-style electric
  piano groove under the demos, a pluck arpeggio lift into the cards, four on the floor with a pluck lead on the cards,
  the tonic on the icon. The music dips about 3 dB under UI sounds, and the mix is mastered to −14 LUFS with a −1.2 dBTP
  ceiling.

Checking without rendering the film: `node render.mjs --stills 5.4,12.4 --lang ko --aspect v` writes PNGs to
`out/stills/`, and `node render.mjs --video out/preview.mp4 --dpr 1 --samples 1 --fps 30` makes a quick preview.

## Requirements and assets

macOS with Google Chrome, Node, Python 3 and ffmpeg. `make.sh` installs the Node packages and a Python venv (numpy,
scipy, pyloudnorm) on first run, exports the SF Symbols the Apple UI needs from this Mac
(`tools/export-symbols.swift`; Apple's symbols aren't redistributed) and builds `src/icons.js`
(`tools/make-icons.mjs`: Nearclip's Material Symbols drawables, Fluent UI System Icons, the brand glyph and a real QR).
Segoe UI, Malgun Gothic and Roboto aren't redistributable either: `render.mjs` reads them from this Mac's Microsoft Office
install (`--fonts` lists what it found) and falls back to system fonts elsewhere. Captions use Pretendard. The Lisbon
photo is the one made for the Pickverter film.
