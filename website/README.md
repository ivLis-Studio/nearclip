# Website

The Nearclip website at [ivlis-studio.github.io/nearclip](https://ivlis-studio.github.io/nearclip/).
Everything in `public/` is published to GitHub Pages by `.github/workflows/website.yml` when it changes on `main`.

Plain HTML, CSS and JavaScript — no build step. The look is the launch film's: Iris, ink and paper, flat colour, big
Pretendard type and hairline rules, with the real apps doing the showing.

```sh
cd website
npm run serve                 # preview at http://127.0.0.1:8766/?lang=ko
npm install && npm test       # smoke test in headless Chrome: both languages, the live demo, tabs, film, links, phone layout
node tools/shot.mjs <url> <out.png> [width] [height] [fullPage] [light|dark] [waitMs] [dpr]
```

- `public/index.html` holds the English copy; `public/assets/js/i18n.js` the Korean copy (by `data-t` key, `data-t-alt` for
  image descriptions), the strings the scripts build, and the live demo's words — the apps' own vocabulary from
  [docs/DESIGN.md](../docs/DESIGN.md) §3. `?lang=en|ko` forces a language, the menu in the header remembers a choice.
- `public/assets/js/demo.js` is the live demo under the hero: four devices, one clipboard. A copy flies straight from one
  device to the other three; images show their progress first, like the apps. It plays by itself while on screen until
  the visitor presses a key on a device, and never with reduced motion.
- `public/assets/js/site.js` picks the download for the visitor's device (`?os=mac|win|android|ios` forces one; Windows
  goes to the Microsoft Store), reads the latest release's version and the repository's star count from GitHub (the count
  shows on the Star buttons from 10 stars up), and runs the pairs table (4 of 12 without Nearclip, 12 with it), the
  examples, the film, the verification-code stage and the image-progress toast.
- The page asks for a GitHub star near the end and links the maker's portfolio, [ivlis.kr](https://ivlis.kr).
- Windows leads with the Microsoft Store listing (`apps.microsoft.com/detail/9PNQ3Z9S83QS`); its card keeps the ZIPs
  below it as the direct download from GitHub.
- Download buttons link to `releases/latest/download/<file>`, so the release assets keep these names:
  `Nearclip-macOS.zip`, `Nearclip-Windows-x64.zip`, `Nearclip-Windows-arm64.zip`, `Nearclip-Android.apk`.
- `public/assets/media/` is made by `tools/media.sh` from the promo film (`promo/`): the 16:9 and 9:16 cuts with their
  posters, stills of the demos and of the four apps (rendered by `promo/render.mjs` at 2×), the social card and the icons
  from `design/out`. `tools/make-qr.mjs` writes the QR code (it opens this site), `tools/make-icons.mjs` the icon set.
- Icons are [Lucide](https://lucide.dev) (ISC). Type is [Pretendard](https://github.com/orioncactus/pretendard) (OFL 1.1),
  served from `public/assets/fonts/pretendard` as its dynamic subset (only the pieces a page uses are downloaded).

