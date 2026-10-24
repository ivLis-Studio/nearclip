// Screenshot of any page in headless Chrome, with reveal animations finished and lazy images loaded.
//   node tools/shot.mjs <url> <out.png> [width=1440] [height=900] [fullPage=1] [light|dark] [waitMs=800] [dpr=1]
import { chromium } from "playwright-core";

const [url, out, w = "1440", h = "900", full = "1", scheme = "light", wait = "800", dpr = "1"] = process.argv.slice(2);
if (!url || !out) {
  console.error("usage: node tools/shot.mjs <url> <out.png> [width] [height] [fullPage 0|1] [light|dark] [waitMs] [dpr]");
  process.exit(2);
}
const browser = await chromium.launch({ channel: "chrome", headless: true, args: ["--force-color-profile=srgb"] });
const page = await browser.newPage({ viewport: { width: +w, height: +h }, deviceScaleFactor: +dpr, colorScheme: scheme });
const errors = [];
page.on("pageerror", (e) => errors.push("pageerror " + e.message));
page.on("console", (m) => { if (m.type() === "error") errors.push("console " + m.text()); });
await page.goto(url, { waitUntil: "networkidle" });
await page.evaluate(() => document.querySelectorAll(".reveal").forEach((n) => n.classList.add("in")));
if (full === "1") {
  await page.evaluate(async () => {
    for (let y = 0; y < document.documentElement.scrollHeight; y += innerHeight / 2) { scrollTo(0, y); await new Promise((r) => setTimeout(r, 160)); }
    scrollTo(0, 0);
  });
}
await page.waitForTimeout(+wait);
await page.screenshot({ path: out, fullPage: full === "1" });
const info = await page.evaluate(() => ({ height: document.documentElement.scrollHeight, overflowX: document.documentElement.scrollWidth > innerWidth }));
console.log(JSON.stringify({ out, ...info, errors }));
await browser.close();

