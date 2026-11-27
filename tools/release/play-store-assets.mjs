// Render existing Nearclip vector artwork and export native Android captures for Google Play.
// node tools/release/play-store-assets.mjs [output-directory]
import fs from "node:fs/promises";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(path.join(root, "design/package.json"));
const sharp = require("sharp");
const out = path.resolve(process.argv[2] || path.join(root, "dist/store/google-play"));
const metadata = JSON.parse(await fs.readFile(path.join(root, "docs/store/google-play.json"), "utf8"));
const glyph = (await fs.readFile(path.join(root, "design/out/glyph-white.svg"), "utf8"))
  .replace(/^<svg[^>]*>/, "").replace(/<\/svg>$/, "");
await fs.mkdir(out, { recursive: true });
await sharp(path.join(root, "design/out/icon-ios.svg")).resize(512, 512).removeAlpha().png().toFile(path.join(out, "icon-512.png"));

for (const [locale, lines] of [
  ["en-US", ["Copy here.", "Paste there."]],
  ["ko-KR", ["여기서 복사하고,", "저기서 붙여넣기."]],
]) {
  const listing = metadata[locale];
  for (const [key, limit] of [["title", 30], ["shortDescription", 80], ["fullDescription", 4000], ["releaseNotes", 500]]) {
    if (!listing[key].trim() || [...listing[key]].length > limit) throw new Error(`${locale}.${key}: exceeds ${limit} characters`);
  }
  const dir = path.join(out, locale);
  await fs.mkdir(dir, { recursive: true });
  for (const [key, value] of Object.entries(listing)) await fs.writeFile(path.join(dir, key + ".txt"), value + "\n");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="500" viewBox="0 0 1024 500">
    <rect width="1024" height="500" fill="#F5F4F0"/>
    <g font-family="Arial, Apple SD Gothic Neo, sans-serif" fill="#111215">
      <text x="64" y="93" font-size="30" font-weight="700">Nearclip</text>
      <text x="60" y="217" font-size="58" font-weight="700" letter-spacing="-2">${lines[0]}</text>
      <text x="60" y="291" font-size="58" font-weight="700" letter-spacing="-2">${lines[1]}</text>
      <text x="64" y="430" font-size="19" fill="#55565D">Mac · Windows · Android · iPhone · iPad</text>
    </g>
    <rect x="706" y="142" width="242" height="242" rx="54" fill="#4C5BF5"/>
    <g transform="translate(706 142) scale(0.236328125)">${glyph}</g>
    <rect x="64" y="340" width="64" height="6" rx="3" fill="#4C5BF5"/>
  </svg>`;
  await fs.writeFile(path.join(dir, "feature-1024x500.svg"), svg);
  await sharp(Buffer.from(svg)).removeAlpha().png().toFile(path.join(dir, "feature-1024x500.png"));
  const lang = locale === "ko-KR" ? "ko" : "en";
  for (const [source, name] of [["01-history.png", "01-history.png"], ["03-devices.png", "02-devices.png"], ["04-add-device.png", "03-add-device.png"], ["07-settings.png", "04-settings.png"]]) {
    // Pixel content is unchanged; Play requires 24-bit RGB PNG rather than the capture's RGBA encoding.
    await sharp(path.join(root, "docs/screenshots/android", lang + "-dark", source)).removeAlpha().png().toFile(path.join(dir, name));
  }
  console.log(locale + ": listing text, feature graphic and four native screenshots exported");
}
console.log(out);
