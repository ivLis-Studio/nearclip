// Renders the Nearclip promo stage (index.html) to stills or video.
//   node render.mjs --stills 3.4,4.9 [--lang ko] [--aspect h|v] [--dpr 1] [--blur]
//   node render.mjs --video out/video-ko-h.mp4 [--lang ko] [--aspect h|v] [--dpr 2] [--fps 60] [--samples 4] [--workers 6]
//   node render.mjs --events out/events-ko.json [--lang ko]
//   node render.mjs --fonts                 (lists the Windows / Android faces found on this Mac)
// --aspect v renders the 9:16 cut (1080×1920 CSS pixels × dpr) for Shorts, Reels and TikTok.
import { chromium } from "playwright-core";
import sharp from "sharp";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = {};
for (let i = 0; i < argv.length; i++) if (argv[i].startsWith("--")) opt[argv[i].slice(2)] = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
const lang = opt.lang || "ko";
const dpr = +(opt.dpr || 1);
const fps = +(opt.fps || 60);
const aspect = opt.aspect === "v" ? "v" : "h";
const W = aspect === "v" ? 1080 : 1920, H = aspect === "v" ? 1920 : 1080;

// Windows (Segoe UI, Malgun Gothic) and Android (Roboto) faces aren't redistributable: read them from wherever this Mac
// has them (Microsoft Office ships them); missing ones fall back in CSS.
const office = path.join(os.homedir(), "Library/Group Containers/UBF8T346G9.Office");
const word = "/Applications/Microsoft Word.app/Contents/Resources/DFonts";
const scan = (dir, depth = 4) => {
  const out = [];
  const walk = (d, n) => {
    let entries = [];
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory() && n > 0) walk(p, n - 1);
      else if (e.isFile()) out.push(p);
    }
  };
  walk(dir, depth);
  return out;
};
const pool = [...scan(path.join(office, "SolutionPackages")), ...scan(path.join(office, "FontCache"), 5), ...scan(word, 0),
  ...scan("/Library/Fonts", 0), ...scan(path.join(os.homedir(), "Library/Fonts"), 0)];
const pick = (...patterns) => {
  for (const re of patterns) { const hit = pool.find((p) => re.test(path.basename(p)) || re.test(p)); if (hit) return hit; }
  return null;
};
const FACES = {
  "segoe-300": pick(/^segoeui-light_.*\.woff2?$/i, /^segoeuil\.ttf$/i),
  "segoe-400": pick(/^segoeui-regular_.*\.woff2?$/i, /^segoeui\.ttf$/i, /CloudFonts\/Segoe UI\/[^/]+\.ttf$/),
  "segoe-600": pick(/^segoeui-semibold_.*\.woff$/i, /^Segoe-UI-Semibold_.*\.woff2$/i, /^seguisb\.ttf$/i),
  "malgun-400": pick(/^malgun\.ttf$/i), "malgun-700": pick(/^malgunbd\.ttf$/i),
  "roboto-400": null, "roboto-700": null,
};
// Office's cloud copies of Roboto have numeric names: read usWeightClass from the OS/2 table.
const weightOf = (file) => {
  const b = fs.readFileSync(file);
  for (let i = 0, n = b.readUInt16BE(4); i < n; i++) {
    const rec = 12 + i * 16;
    if (b.toString("latin1", rec, rec + 4) === "OS/2") return b.readUInt16BE(b.readUInt32BE(rec + 8) + 4);
  }
  return 400;
};
for (const p of pool.filter((p) => /CloudFonts\/Roboto\/[^/]+\.ttf$/.test(p))) FACES[weightOf(p) >= 600 ? "roboto-700" : "roboto-400"] = p;
const SERVED = {};
for (const [name, file] of Object.entries(FACES)) if (file) SERVED["/winfonts/" + name] = file;
if (opt.fonts) { for (const [name, file] of Object.entries(FACES)) console.log(name.padEnd(12), file || "— (falls back)"); process.exit(0); }

const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png", ".jpg": "image/jpeg",
  ".json": "application/json", ".svg": "image/svg+xml", ".ttf": "font/ttf", ".woff": "font/woff", ".woff2": "font/woff2" };
const server = http.createServer((req, res) => {
  const pathname = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (pathname === "/favicon.ico") { res.writeHead(204); res.end(); return; }
  const file = SERVED[pathname] || path.join(here, pathname);
  if ((!SERVED[pathname] && !file.startsWith(here)) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "Content-Type": TYPES[path.extname(file)] || "application/octet-stream", "Cache-Control": "max-age=3600" });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const origin = "http://127.0.0.1:" + server.address().port;

async function openPage(browser, url = "/index.html", size = { width: W, height: H }) {
  const page = await browser.newPage({ viewport: size, deviceScaleFactor: dpr });
  page.on("pageerror", (e) => console.error("page error:", e.message));
  page.on("console", (m) => { if (m.type() === "error") console.error("console:", m.text()); });
  await page.addInitScript("window.LANG = " + JSON.stringify(lang) + "; window.ASPECT = " + JSON.stringify(aspect) + ";");
  await page.goto(origin + url);
  await page.evaluate(() => window.ready);
  const cdp = await page.context().newCDPSession(page);
  return { page, cdp };
}

async function frame({ page, cdp }, t) {
  await page.evaluate((t) => { window.renderAt(t); return new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))); }, t);
  const { data } = await cdp.send("Page.captureScreenshot", { format: "png", optimizeForSpeed: true, clip: { x: 0, y: 0, width: W, height: H, scale: dpr } });
  return Buffer.from(data, "base64");
}

// Motion blur: average sub-frames across a 180° shutter centred on t. The stage can ask for more samples in
// fast windows (window.MOTION_BLUR).
let blurWindows = [];
const baseSamples = +(opt.samples || 1);
function samplesAt(t) {
  for (const w of blurWindows) if (t >= w.from && t < w.to) return Math.max(w.samples, baseSamples);
  return baseSamples;
}
async function blurredFrame(p, t) {
  const n = samplesAt(t);
  if (n <= 1) return frame(p, t);
  const shutter = 0.5 / fps;
  let acc = null, info = null;
  for (let k = 0; k < n; k++) {
    const png = await frame(p, t - shutter / 2 + (shutter * (k + 0.5)) / n);
    const { data, info: i } = await sharp(png).raw().toBuffer({ resolveWithObject: true });
    info = i;
    if (!acc) acc = new Uint16Array(data.length);
    for (let j = 0; j < data.length; j++) acc[j] += data[j];
  }
  const out = Buffer.allocUnsafe(acc.length);
  for (let j = 0; j < acc.length; j++) out[j] = (acc[j] + (n >> 1)) / n;
  return sharp(out, { raw: { width: info.width, height: info.height, channels: info.channels } }).png({ compressionLevel: 1 }).toBuffer();
}

const browser = await chromium.launch({ channel: "chrome", headless: true, timeout: 60000, args: ["--force-color-profile=srgb", "--disable-lcd-text", "--hide-scrollbars", "--font-render-hinting=none"] });

if (opt.events) {
  const { page } = await openPage(browser);
  const data = await page.evaluate(() => ({ duration: window.DURATION, music: window.MUSIC, events: window.AUDIO_EVENTS }));
  fs.writeFileSync(opt.events, JSON.stringify(data, null, 1));
  console.log(opt.events, data.events.length, "events");
}

if (opt.stills) {
  const p = await openPage(browser);
  blurWindows = await p.page.evaluate(() => window.MOTION_BLUR || []);
  const dir = path.join(here, opt.dir || "out/stills");
  fs.mkdirSync(dir, { recursive: true });
  for (const t of String(opt.stills).split(",").map(Number)) {
    const out = path.join(dir, lang + (aspect === "v" ? "-v" : "") + "-" + t.toFixed(2) + ".png");
    fs.writeFileSync(out, await (opt.blur ? blurredFrame(p, t) : frame(p, t)));
    console.log(out);
  }
}

const crf = opt.crf || (dpr > 1 ? "14" : "15");

// One chunk of frames [first, last) → an H.264 file, in its own process.
if (opt.chunk) {
  const from = +opt.from, first = +opt.first, last = +opt.last;
  const p = await openPage(browser);
  blurWindows = await p.page.evaluate(() => window.MOTION_BLUR || []);
  const ff = spawn("ffmpeg", ["-v", "error", "-y", "-f", "image2pipe", "-framerate", String(fps), "-c:v", "png", "-i", "-",
    "-c:v", "libx264", "-preset", "slow", "-crf", crf, "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
    "-threads", "2", "-x264-params", "keyint=" + fps * 2, opt.chunk], { stdio: ["pipe", "inherit", "inherit"] });
  for (let f = first; f < last; f++) {
    const buf = await blurredFrame(p, from + f / fps);
    if (!ff.stdin.write(buf)) await new Promise((r) => ff.stdin.once("drain", r));
    if ((f - first + 1) % 30 === 0) console.log("+30");
  }
  ff.stdin.end();
  await new Promise((r) => ff.on("close", r));
}

if (opt.video) {
  const from = +(opt.from || 0), to = +(opt.to || (await (await openPage(browser)).page.evaluate(() => window.DURATION)));
  const total = Math.round((to - from) * fps);
  const workers = Math.max(1, +(opt.workers || 6));
  const size = Math.ceil(total / (workers * 3));
  fs.mkdirSync(path.join(here, "out"), { recursive: true });
  const tmp = fs.mkdtempSync(path.join(here, "out/.chunks-"));
  const started = Date.now();
  let done = 0;
  const queue = [];
  for (let first = 0, i = 0; first < total; first += size, i++) queue.push({ first, last: Math.min(total, first + size), file: path.join(tmp, "c" + String(i).padStart(3, "0") + ".mp4") });
  const files = queue.map((q) => q.file);
  const pass = ["--lang", lang, "--aspect", aspect, "--dpr", String(dpr), "--fps", String(fps), "--samples", String(baseSamples), "--crf", crf, "--from", String(from)];
  async function worker() {
    while (queue.length) {
      const q = queue.shift();
      for (let attempt = 1; ; attempt++) {
        let counted = 0;
        try {
          await new Promise((resolve, reject) => {
            const child = spawn(process.execPath, [fileURLToPath(import.meta.url), "--chunk", q.file, "--first", String(q.first), "--last", String(q.last), ...pass], { stdio: ["ignore", "pipe", "inherit"] });
            child.stdout.on("data", (d) => {
              const n = 30 * (String(d).match(/\+30/g) || []).length;
              counted += n;
              done += n;
              const el = (Date.now() - started) / 1000;
              process.stdout.write("frames ~" + done + "/" + total + "  " + (done / el).toFixed(1) + " fps  eta " + Math.round(((total - done) * el) / Math.max(1, done)) + "s\n");
            });
            child.on("close", (code) => (code === 0 ? resolve() : reject(new Error("chunk failed " + q.file))));
          });
          break;
        } catch (error) {
          done -= counted;
          if (attempt >= 3) throw error;
          console.error("retrying " + path.basename(q.file) + " (" + error.message + ")");
        }
      }
    }
  }
  await Promise.all(Array.from({ length: workers }, worker));
  const list = path.join(tmp, "list.txt");
  fs.writeFileSync(list, files.map((f) => "file '" + f + "'").join("\n"));
  await new Promise((r) => spawn("ffmpeg", ["-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", "-movflags", "+faststart", opt.video], { stdio: "inherit" }).on("close", r));
  for (const f of [...files, list]) fs.rmSync(f, { force: true });
  fs.rmdirSync(tmp);
  console.log(opt.video, "in", Math.round((Date.now() - started) / 1000) + "s");
}

await browser.close();
server.close();

