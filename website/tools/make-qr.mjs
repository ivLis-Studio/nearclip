// Writes public/assets/media/qr.svg — the QR code in "How it works". It opens this site (a real pairing code carries a
// one-time secret, so the page never shows one).   node tools/make-qr.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import QRCode from "qrcode";

const here = path.dirname(fileURLToPath(import.meta.url));
const svg = await QRCode.toString("https://ivlis-studio.github.io/nearclip/", { type: "svg", errorCorrectionLevel: "H", margin: 0, color: { dark: "#1D1D1F", light: "#FFFFFF" } });
fs.writeFileSync(path.join(here, "../public/assets/media/qr.svg"), svg);
console.log("qr.svg", svg.length, "bytes");

