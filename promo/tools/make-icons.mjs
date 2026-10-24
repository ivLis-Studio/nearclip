// Collects the icons the stage draws into src/icons.js (run by make.sh when it is missing):
//   Android: Nearclip's own Material Symbols drawables (android/app/src/main/res/drawable, Apache-2.0)
//   Windows: Fluent UI System Icons (@fluentui/svg-icons, MIT), the open versions of the app's Segoe Fluent glyphs
//   Brand:   the glyph geometry of design/make-icons.mjs
//   node tools/make-icons.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const QRCode = require("qrcode");

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "..");
const drawables = path.join(root, "../android/app/src/main/res/drawable");
const fluent = path.join(root, "node_modules/@fluentui/svg-icons/icons");

const MATERIAL = ["search", "settings", "notes", "link", "image", "laptop_mac", "phone_iphone", "smartphone", "desktop_windows",
  "computer", "push_pin", "push_pin_filled", "check", "devices", "content_paste_go", "content_paste", "content_copy", "share",
  "more_vert", "lock", "public", "qr_code_2", "qr_code_scanner", "wifi", "send", "add", "sync", "history", "check_circle_filled",
  "arrow_back", "close", "pause", "photo_camera", "wifi_tethering", "lan"];
const FLUENT = ["search_20_regular", "more_horizontal_20_regular", "laptop_20_regular", "laptop_16_regular", "desktop_20_regular",
  "desktop_16_regular", "phone_20_regular", "phone_16_regular", "add_20_regular", "pause_20_regular", "pin_16_filled",
  "text_align_left_20_regular", "link_20_regular", "image_20_regular", "copy_20_regular", "clipboard_paste_20_regular",
  "dismiss_20_regular", "chevron_right_20_regular", "globe_20_regular", "lock_closed_20_regular", "checkmark_circle_20_filled",
  "wifi_1_20_regular", "speaker_2_20_regular", "battery_10_20_regular", "arrow_left_20_regular", "arrow_right_20_regular",
  "arrow_clockwise_20_regular", "star_20_regular", "subtract_20_regular", "square_20_regular", "shield_lock_20_regular",
  "person_20_regular", "folder_20_filled", "document_20_regular", "window_20_regular", "grid_20_regular", "mail_20_regular",
  "settings_20_regular", "home_20_regular", "lock_closed_16_filled", "info_20_regular", "add_16_regular", "chevron_down_20_regular"];

// Android vector drawable → SVG (groups with translate/scale, paths with fill/stroke and alphas).
function vectorToSvg(xml) {
  const vw = +xml.match(/android:viewportWidth="([\d.]+)"/)[1];
  const vh = +xml.match(/android:viewportHeight="([\d.]+)"/)[1];
  const body = xml.slice(xml.indexOf(">", xml.indexOf("<vector")) + 1, xml.lastIndexOf("</vector>"));
  const out = body
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<group([^>]*)>/g, (_, a) => {
      const g = (k, d) => { const m = a.match(new RegExp('android:' + k + '="([-\\d.]+)"')); return m ? +m[1] : d; };
      return '<g transform="translate(' + g("translateX", 0) + " " + g("translateY", 0) + ") scale(" + g("scaleX", 1) + " " + g("scaleY", 1) + ')">';
    })
    .replace(/<\/group>/g, "</g>")
    .replace(/<path([^>]*?)\/>/g, (_, a) => {
      const at = (k) => { const m = a.match(new RegExp('android:' + k + '="([^"]*)"')); return m ? m[1] : null; };
      const color = (c) => (c && c.length === 9 ? "#" + c.slice(3) : c);
      const fill = at("fillColor"), stroke = at("strokeColor");
      const parts = ['<path d="' + at("pathData") + '"'];
      // Single-colour icons follow currentColor; the brand glyph keeps its own colours.
      const mono = (c) => (c && /^#?F{6,8}$/i.test(c.replace("#", "")) ? "currentColor" : color(c));
      parts.push(' fill="' + (fill ? mono(fill) : "none") + '"');
      if (at("fillAlpha")) parts.push(' fill-opacity="' + at("fillAlpha") + '"');
      if (stroke) parts.push(' stroke="' + mono(stroke) + '" stroke-width="' + at("strokeWidth") + '" stroke-linecap="' + (at("strokeLineCap") || "butt") + '"');
      if (at("strokeAlpha")) parts.push(' stroke-opacity="' + at("strokeAlpha") + '"');
      return parts.join("") + "/>";
    });
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + vw + " " + vh + '">' + out.replace(/\s+/g, " ").trim() + "</svg>";
}

const icons = { m: {}, f: {} };
for (const name of MATERIAL) {
  const file = path.join(drawables, "ic_" + name + ".xml");
  if (!fs.existsSync(file)) { console.warn("missing material", name); continue; }
  icons.m[name] = vectorToSvg(fs.readFileSync(file, "utf8"));
}
for (const name of FLUENT) {
  const file = path.join(fluent, name + ".svg");
  if (!fs.existsSync(file)) { console.warn("missing fluent", name); continue; }
  icons.f[name.replace(/_(16|20)_(regular|filled)$/, (m, s, k) => (k === "filled" ? "_filled" : "") + (s === "16" ? "_16" : ""))] =
    fs.readFileSync(file, "utf8").replace("<svg ", '<svg fill="currentColor" ').replace(/ width="\d+" height="\d+"/, "");
}

// The Nearclip glyph (design/make-icons.mjs), parameterised by colours.
const glyph = (fg, accent, back = 0.34, lines = true) => [
  '<g transform="translate(512 512) scale(1.06) translate(-512 -512) translate(-46 34)">',
  '<rect x="232" y="268" width="352" height="432" rx="76" fill="' + fg + '" fill-opacity="' + back + '"/>',
  '<rect x="376" y="364" width="352" height="432" rx="76" fill="' + fg + '"/>',
  lines ? '<rect x="440" y="468" width="224" height="40" rx="20" fill="' + accent + '" fill-opacity="0.30"/>' : "",
  lines ? '<rect x="440" y="548" width="224" height="40" rx="20" fill="' + accent + '" fill-opacity="0.30"/>' : "",
  lines ? '<rect x="440" y="628" width="140" height="40" rx="20" fill="' + accent + '" fill-opacity="0.30"/>' : "",
  '<path d="M 700 244 A 104 104 0 0 1 804 348" stroke="' + fg + '" stroke-width="40" stroke-linecap="round" fill="none"/>',
  '<path d="M 700 164 A 184 184 0 0 1 884 348" stroke="' + fg + '" stroke-width="40" stroke-linecap="round" fill="none" stroke-opacity="0.55"/>',
  "</g>",
].join("");
const svg = (inner) => '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">' + inner + "</svg>";
icons.brand = {
  glyph: svg(glyph("#FFFFFF", "#4C5BF5")),
  glyphIris: svg(glyph("#4C5BF5", "#FFFFFF", 0.28)),
  tile: svg('<rect width="1024" height="1024" fill="#4C5BF5"/>' + glyph("#FFFFFF", "#4C5BF5")),
  macos: svg('<rect x="100" y="100" width="824" height="824" rx="185" fill="#4C5BF5"/><g transform="translate(100 100) scale(0.8047)">' + glyph("#FFFFFF", "#4C5BF5") + "</g>"),
  // Menu bar / tray template (design/make-icons.mjs monoGlyph)
  mono: svg('<g transform="translate(512 512) scale(1.18) translate(-512 -512) translate(-46 34)" fill="currentColor"><path fill-rule="evenodd" d="M308 268 h200 a76 76 0 0 1 76 76 v20 h-64 v-20 a12 12 0 0 0 -12 -12 h-200 a12 12 0 0 0 -12 12 v280 a12 12 0 0 0 12 12 h52 v64 h-52 a76 76 0 0 1 -76 -76 v-280 a76 76 0 0 1 76 -76 z"/><rect x="376" y="364" width="352" height="432" rx="76"/><path d="M 700 244 A 104 104 0 0 1 804 348" stroke="currentColor" stroke-width="56" stroke-linecap="round" fill="none"/><path d="M 700 140 A 208 208 0 0 1 908 348" stroke="currentColor" stroke-width="56" stroke-linecap="round" fill="none"/></g>'),
};

const js = "// Generated by tools/make-icons.mjs — do not edit.\nwindow.NC_ICONS = " + JSON.stringify(icons) + ";\n";

// A real, scannable QR (it reads "Nearclip · Copy here. Paste there.") drawn like the app's Add Device code: rounded
// Iris modules, high error correction and the brand tile over the centre.
{
  const qr = QRCode.create("Nearclip · Copy here. Paste there.", { errorCorrectionLevel: "H" });
  const n = qr.modules.size, m = 2, size = n + 2 * m;
  const hole = Math.ceil(n * 0.24 / 2) * 2 + 1, h0 = (n - hole) / 2;
  let d = "";
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
    if (!qr.modules.get(x, y)) continue;
    if (x >= h0 - 0.5 && x < h0 + hole && y >= h0 - 0.5 && y < h0 + hole) continue;
    d += "M" + (x + m + 0.08) + " " + (y + m + 0.08) + "h0.84v0.84h-0.84z";
  }
  const tile = (n / 2 + m) - hole / 2 + 0.6, ts = hole - 1.2;
  icons.brand.qr = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + size + " " + size + '"><rect width="' + size + '" height="' + size + '" rx="2.4" fill="#fff"/><path d="' + d + '" fill="#2a2f6e"/>' +
    '<svg x="' + tile + '" y="' + tile + '" width="' + ts + '" height="' + ts + '" viewBox="0 0 1024 1024"><rect width="1024" height="1024" rx="230" fill="#4C5BF5"/>' + glyph("#FFFFFF", "#4C5BF5") + "</svg></svg>";
}
const out = "// Generated by tools/make-icons.mjs — do not edit.\nwindow.NC_ICONS = " + JSON.stringify(icons) + ";\n";
fs.writeFileSync(path.join(root, "src/icons.js"), out);
console.log("src/icons.js:", Object.keys(icons.m).length, "material,", Object.keys(icons.f).length, "fluent");
