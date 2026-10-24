# Website

The Nearclip website at [ivlis-studio.github.io/nearclip](https://ivlis-studio.github.io/nearclip/).
Everything in `public/` is published to GitHub Pages by `.github/workflows/website.yml` when it changes on `main`.

Plain HTML, CSS and JavaScript — no build step.

```sh
cd website
npm run serve                 # preview at http://127.0.0.1:8766/?lang=ko
npm install && npm test       # smoke test in headless Chrome: both languages, the live demo, tabs, film, links, phone layout
node tools/shot.mjs <url> <out.png> [width] [height] [fullPage] [light|dark] [waitMs] [dpr]
```

- `public/index.html` holds the English copy; `public/assets/js/i18n.js` the Korean copy (by `data-t` key, `data-t-alt` for
  image descriptions), the strings the scripts build, and the live demo's words — the apps' own vocabulary from
  [docs/DESIGN.md](../docs/DESIGN.md) §3. `?lang=en|ko` forces a language, the menu in the header remembers a choice.
- `public/assets/js/demo.js` is the live demo in the hero: four devices, one clipboard. A copy flies straight from one
  device to the other three; images show their progress first, like the apps. It plays by itself while on screen until
  the visitor presses a key on a device, and never with reduced motion.
- `public/assets/js/site.js` picks the download for the visitor's device (`?os=mac|win|android|ios` forces one; Windows on
  Arm gets the Arm64 build), reads the latest release's version from GitHub, and runs the examples, the film and the
  image-progress toast.
- Download buttons link to `releases/latest/download/<file>`, so the release assets keep these names:
  `Nearclip-macOS.zip`, `Nearclip-Windows-x64.zip`, `Nearclip-Windows-arm64.zip`, `Nearclip-Android.apk`.
- `public/assets/media/` is made by `tools/media.sh` from the promo film (`promo/`): the 16:9 and 9:16 cuts with their
  posters, stills of the demos and of the four apps (rendered by `promo/render.mjs` at 2×), the social card and the icons
  from `design/out`. `tools/make-qr.mjs` writes the QR code (it opens this site), `tools/make-icons.mjs` the icon set.
- Icons are [Lucide](https://lucide.dev) (ISC).

