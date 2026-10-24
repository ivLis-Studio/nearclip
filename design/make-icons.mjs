#!/usr/bin/env node
// Nearclip brand assets. One geometry, every platform.
//   cd design && npm install && node make-icons.mjs
// Outputs to design/out/: iOS/macOS/Windows icons, tray icons, menu bar template, glyph SVGs.
import sharp from "sharp";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "out");
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

export const IRIS = "#4C5BF5";

// Glyph on a 1024 canvas, optically centred. fg = card colour, accent = line colour (usually the plate colour).
function glyph({ fg = "#FFFFFF", accent = IRIS, backOpacity = 0.34, lines = true, arcs = true, outerArc = 0.55 } = {}) {
  return [
    '<g transform="translate(512 512) scale(1.06) translate(-512 -512) translate(-46 34)">',
    '<rect x="232" y="268" width="352" height="432" rx="76" fill="' + fg + '" fill-opacity="' + backOpacity + '"/>',
    '<rect x="376" y="364" width="352" height="432" rx="76" fill="' + fg + '"/>',
    lines ? '<rect x="440" y="468" width="224" height="40" rx="20" fill="' + accent + '" fill-opacity="0.30"/>' : "",
    lines ? '<rect x="440" y="548" width="224" height="40" rx="20" fill="' + accent + '" fill-opacity="0.30"/>' : "",
    lines ? '<rect x="440" y="628" width="140" height="40" rx="20" fill="' + accent + '" fill-opacity="0.30"/>' : "",
    arcs ? '<path d="M 700 244 A 104 104 0 0 1 804 348" stroke="' + fg + '" stroke-width="40" stroke-linecap="round" fill="none"/>' : "",
    arcs ? '<path d="M 700 164 A 184 184 0 0 1 884 348" stroke="' + fg + '" stroke-width="40" stroke-linecap="round" fill="none" stroke-opacity="' + outerArc + '"/>' : "",
    "</g>",
  ].join("");
}
const svg = (inner, size = 1024) => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="' + size + '" height="' + size + '">' + inner + "</svg>";

// Monochrome glyph for small sizes (tray/menu bar): solid shapes, back card as outline so it reads at 16 px.
function monoGlyph(color) {
  return [
    '<g transform="translate(512 512) scale(1.18) translate(-512 -512) translate(-46 34)">',
    '<path fill-rule="evenodd" fill="' + color + '" d="M308 268 h200 a76 76 0 0 1 76 76 v20 h-64 v-20 a12 12 0 0 0 -12 -12 h-200 a12 12 0 0 0 -12 12 v280 a12 12 0 0 0 12 12 h52 v64 h-52 a76 76 0 0 1 -76 -76 v-280 a76 76 0 0 1 76 -76 z"/>',
    '<rect x="376" y="364" width="352" height="432" rx="76" fill="' + color + '"/>',
    '<path d="M 700 244 A 104 104 0 0 1 804 348" stroke="' + color + '" stroke-width="56" stroke-linecap="round" fill="none"/>',
    '<path d="M 700 140 A 208 208 0 0 1 908 348" stroke="' + color + '" stroke-width="56" stroke-linecap="round" fill="none"/>',
    "</g>",
  ].join("");
}

const files = {
  // iOS / iPadOS: full-bleed square, the system applies the mask.
  "icon-ios.svg": svg('<rect width="1024" height="1024" fill="' + IRIS + '"/>' + glyph()),
  // macOS: 824 pt plate on the 1024 grid with Apple's corner radius and a soft shadow.
  "icon-macos.svg": svg(
    '<defs><filter id="s" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.28"/></filter></defs>' +
    '<rect x="100" y="100" width="824" height="824" rx="185" fill="' + IRIS + '" filter="url(#s)"/>' +
    '<g transform="translate(100 100) scale(0.8047)">' + glyph() + "</g>"),
  // Windows: plate fills the canvas with a small margin and Windows-like radius.
  "icon-windows.svg": svg('<rect x="32" y="32" width="960" height="960" rx="200" fill="' + IRIS + '"/>' + '<g transform="translate(32 32) scale(0.9375)">' + glyph() + "</g>"),
  // Android adaptive foreground (108dp canvas, glyph inside the 66dp safe zone) and background colour.
  "android-foreground.svg": svg('<g transform="translate(512 512) scale(0.62) translate(-512 -512)">' + glyph() + "</g>"),
  "android-monochrome.svg": svg('<g transform="translate(512 512) scale(0.62) translate(-512 -512)">' + glyph({ fg: "#000000", accent: "#FFFFFF", lines: false, backOpacity: 0.5, outerArc: 0.6 }) + "</g>"),
  "glyph-white.svg": svg(glyph({ lines: true })),
  "mono-black.svg": svg(monoGlyph("#000000")),
  "mono-white.svg": svg(monoGlyph("#FFFFFF")),
};
for (const [name, s] of Object.entries(files)) writeFileSync(join(out, name), s);

const png = (name, size, file) => sharp(Buffer.from(files[name])).resize(size, size).png().toFile(join(out, file));

// iOS 1024 (opaque)
await sharp(Buffer.from(files["icon-ios.svg"])).resize(1024, 1024).flatten({ background: IRIS }).png().toFile(join(out, "ios-1024.png"));
// macOS iconset
mkdirSync(join(out, "macos.iconset"), { recursive: true });
for (const s of [16, 32, 128, 256, 512]) {
  await png("icon-macos.svg", s, "macos.iconset/icon_" + s + "x" + s + ".png");
  await png("icon-macos.svg", s * 2, "macos.iconset/icon_" + s + "x" + s + "@2x.png");
}
// Windows ICO + PNGs
const winSizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256];
const winPngs = [];
for (const s of winSizes) { const f = "win-" + s + ".png"; await png("icon-windows.svg", s, f); winPngs.push(join(out, f)); }
execFileSync("magick", [...winPngs, join(out, "Nearclip.ico")]);
for (const s of [44, 50, 150, 310]) await png("icon-windows.svg", s, "win-tile-" + s + ".png");
// Tray icons (Windows): white glyph for dark taskbars, black for light ones
for (const [tone, name] of [["dark", "mono-white.svg"], ["light", "mono-black.svg"]]) {
  const fs = [];
  for (const s of [16, 20, 24, 32, 40, 48]) { const f = "tray-" + tone + "-" + s + ".png"; await png(name, s, f); fs.push(join(out, f)); }
  execFileSync("magick", [...fs, join(out, "Tray-" + (tone === "dark" ? "Dark" : "Light") + ".ico")]);
}
// macOS menu bar template (black + alpha), 18 pt
await png("mono-black.svg", 18, "MenuBarTemplate.png");
await png("mono-black.svg", 36, "MenuBarTemplate@2x.png");
await png("mono-black.svg", 54, "MenuBarTemplate@3x.png");
// Android legacy launcher PNGs (adaptive icons use the vector drawables in the app)
for (const [d, s] of [["mdpi", 48], ["hdpi", 72], ["xhdpi", 96], ["xxhdpi", 144], ["xxxhdpi", 192]]) {
  await sharp(Buffer.from(files["icon-ios.svg"])).resize(s, s).composite([{ input: Buffer.from('<svg width="' + s + '" height="' + s + '"><rect width="' + s + '" height="' + s + '" rx="' + (s * 0.22) + '" fill="#fff"/></svg>'), blend: "dest-in" }]).png().toFile(join(out, "android-legacy-" + d + ".png"));
}
// Store / README art
await png("icon-macos.svg", 512, "nearclip-512.png");
// In-app brand mark (full-bleed square; the UI rounds the corners itself)
for (const s of [64, 128, 192, 256]) await png("icon-ios.svg", s, "brandmark-" + s + ".png");
// Microsoft Store (MSIX) logos for windows/packaging/Images: the Windows icon on a transparent canvas at every scale
// and target size the package manifest can ask for (resources.pri resolves the qualified names).
mkdirSync(join(out, "msix"), { recursive: true });
const SCALES = [100, 125, 150, 200, 400];
async function msixImage(file, w, h, iconFraction) {
  const size = Math.round(Math.min(w, h) * iconFraction);
  const icon = await sharp(Buffer.from(files["icon-windows.svg"])).resize(size, size).png().toBuffer();
  await sharp({ create: { width: w, height: h, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: icon, left: Math.round((w - size) / 2), top: Math.round((h - size) / 2) }]).png().toFile(join(out, "msix", file));
}
for (const s of SCALES) {
  const k = s / 100;
  await msixImage("Square44x44Logo.scale-" + s + ".png", Math.round(44 * k), Math.round(44 * k), 1);
  await msixImage("Square150x150Logo.scale-" + s + ".png", Math.round(150 * k), Math.round(150 * k), 0.66);
  await msixImage("Wide310x150Logo.scale-" + s + ".png", Math.round(310 * k), Math.round(150 * k), 0.66);
  await msixImage("SmallTile.scale-" + s + ".png", Math.round(71 * k), Math.round(71 * k), 0.8);
  await msixImage("LargeTile.scale-" + s + ".png", Math.round(310 * k), Math.round(310 * k), 0.5);
  await msixImage("StoreLogo.scale-" + s + ".png", Math.round(50 * k), Math.round(50 * k), 1);
}
for (const t of [16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 256]) {
  for (const form of ["", "_altform-unplated", "_altform-lightunplated"]) await msixImage("Square44x44Logo.targetsize-" + t + form + ".png", t, t, 1);
}
console.log("icons written to", out);

