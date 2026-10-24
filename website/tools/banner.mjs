// Renders the README banners from tools/banner.html: docs/readme/banner-<en|ko>-<light|dark>.png (3200×1200).
//   node tools/banner.mjs
import { chromium } from "playwright-core";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "../../docs/readme");
const browser = await chromium.launch({ channel: "chrome", headless: true, args: ["--force-color-profile=srgb"] });
for (const lang of ["en", "ko"]) {
  for (const scheme of ["light", "dark"]) {
    const page = await browser.newPage({ viewport: { width: 1600, height: 600 }, deviceScaleFactor: 2, colorScheme: scheme, reducedMotion: "reduce" });
    await page.goto(pathToFileURL(path.join(here, "banner.html")).href + "?lang=" + lang);
    await page.waitForTimeout(500);
    const file = path.join(out, "banner-" + lang + "-" + scheme + ".png");
    await page.screenshot({ path: file, omitBackground: true });
    console.log(file);
    await page.close();
  }
}
await browser.close();

