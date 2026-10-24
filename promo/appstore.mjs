// Renders promo/appstore.html for each job: node appstore.mjs '<json [{query, out, w, h}]>'
import { chromium } from "playwright-core";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const jobs = JSON.parse(process.argv[2]);
const browser = await chromium.launch({ channel: "chrome", headless: true, args: ["--force-color-profile=srgb", "--allow-file-access-from-files"] });
for (const { query, out, w, h } of jobs) {
  const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
  await page.goto(pathToFileURL(path.join(here, "appstore.html")).href + "?" + query);
  await page.waitForFunction(() => document.body.dataset.ready === "1", null, { timeout: 15000 });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(300);
  await page.screenshot({ path: out });
  await page.close();
  console.log(out);
}
await browser.close();

