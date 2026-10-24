// Renders promo/store.html at a given size: node store.mjs "<query>" <out.png> <width> <height> [dpr]
import { chromium } from "playwright-core";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const [query, out, w, h, dpr = "1"] = process.argv.slice(2);
const browser = await chromium.launch({ channel: "chrome", headless: true, args: ["--force-color-profile=srgb", "--allow-file-access-from-files"] });
const page = await browser.newPage({ viewport: { width: +w, height: +h }, deviceScaleFactor: +dpr });
await page.goto(pathToFileURL(path.join(here, "store.html")).href + "?" + query);
await page.evaluate(() => document.fonts.ready);
await page.waitForTimeout(400);
await page.screenshot({ path: out });
await browser.close();
console.log(out);

