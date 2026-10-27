// Smoke test for the Nearclip site in headless Chrome. Serves public/ on a free port; GitHub's API (latest release, star count) is answered locally.
//   npm install && npm test
import { chromium } from "playwright-core";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, "../public");
const TYPES = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".png": "image/png", ".webp": "image/webp", ".svg": "image/svg+xml", ".mp4": "video/mp4" };
const server = http.createServer((req, res) => {
  let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (p.endsWith("/")) p += "index.html";
  const file = path.join(root, p);
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "Content-Type": TYPES[path.extname(file)] || "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const BASE = "http://127.0.0.1:" + server.address().port + "/";

let failures = 0, checks = 0;
const ok = (cond, what) => { checks++; if (!cond) { failures++; console.log("  ✗ " + what); } };
const DL = "https://github.com/ivLis-Studio/nearclip/releases/download/v1.0.0/";
const STORE = "https://apps.microsoft.com/detail/9PNQ3Z9S83QS";
const RELEASE = { tag_name: "v1.0.0", published_at: "2026-10-24T12:00:00Z",
  assets: ["Nearclip-macOS.zip", "Nearclip-Windows-x64.zip", "Nearclip-Windows-arm64.zip", "Nearclip-Android.apk", "Nearclip-iOS.ipa"].map((name) => ({ name, browser_download_url: DL + name })) };

const browser = await chromium.launch({ channel: "chrome", headless: true });
const REPO_URL = "https://github.com/ivLis-Studio/nearclip";
async function open(url, opts = {}) {
  const ctx = await browser.newContext({ viewport: opts.viewport || { width: 1440, height: 900 }, reducedMotion: opts.reduce ? "reduce" : "no-preference", colorScheme: opts.scheme || "light", isMobile: !!opts.mobile, hasTouch: !!opts.mobile });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  await page.route("https://api.github.com/**", (r) => {
    if (r.request().url().endsWith("/releases/latest")) return r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(RELEASE) });
    return r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ stargazers_count: opts.stars == null ? 1234 : opts.stars }) });
  });
  await page.goto(BASE + url, { waitUntil: "load" });
  return { page, ctx, errors };
}

// ---- 1. every page and asset it names exists
console.log("assets and links");
for (const file of ["index.html", "privacy.html", "404.html"]) {
  const html = fs.readFileSync(path.join(root, file), "utf8");
  const refs = [...html.matchAll(/(?:src|href|poster|data-src-l)="([^"#][^"]*)"/g)].map((m) => m[1]).filter((u) => !/^(https?:|mailto:|\?)/.test(u));
  for (let ref of refs) {
    ref = ref.replace(/^\/nearclip\//, "").replace("%L", "ko");
    if (ref === "./") continue;
    ok(fs.existsSync(path.join(root, ref)), file + " → " + ref + " exists");
    if (ref.includes("-ko.")) ok(fs.existsSync(path.join(root, ref.replace("-ko.", "-en."))), file + " → " + ref.replace("-ko.", "-en.") + " exists");
  }
  ok(!/pickverter/i.test(html), file + " never mentions Pickverter");
  const gh = [...html.matchAll(/https:\/\/github\.com\/([^/"]+)\/([^/"#?]+)/g)].map((m) => m[1] + "/" + m[2]);
  ok(gh.every((r) => r === "ivLis-Studio/nearclip"), file + " links only to ivLis-Studio/nearclip (" + [...new Set(gh)].join(", ") + ")");
  if (file !== "404.html") ok(html.includes('href="https://ivlis.kr"'), file + " links to ivlis.kr");
}

// ---- 2. both languages on every platform: translations, download button, release info
for (const lang of ["en", "ko"]) {
  for (const os of ["mac", "win", "android", "ios"]) {
    const { page, ctx, errors } = await open("?lang=" + lang + "&os=" + os);
    await page.waitForTimeout(300);
    const r = await page.evaluate(() => {
      const dict = window.SITE_I18N.ko;
      const keys = [...new Set([...document.querySelectorAll("[data-t]")].map((n) => n.dataset.t).concat([...document.querySelectorAll("[data-t-alt]")].map((n) => n.dataset.tAlt)))];
      return {
        lang: document.documentElement.lang, title: document.title, h1: document.querySelector("h1").textContent,
        missing: keys.filter((k) => !(k in dict)), unused: Object.keys(dict).filter((k) => !keys.includes(k)),
        main: document.querySelector(".dl-main").getAttribute("href"), label: document.querySelector(".dl-main-label").textContent,
        icon: document.querySelector(".dl-main .ico").dataset.i, painted: !!document.querySelector(".dl-main .ico svg path"),
        win: [...document.querySelectorAll("#dl-win .btns a")].map((a) => a.getAttribute("href")), or: document.querySelector("#dl-win .dl-or").textContent,
        star: [...document.querySelectorAll(".star-mini, .star-cta")].map((a) => a.getAttribute("href") + " " + (a.querySelector(".star-count").hidden ? "-" : a.querySelector(".star-count").textContent)),
        maker: document.querySelectorAll('a[href="https://ivlis.kr"]').length,
        soon: ["mac", "android", "ios"].map((p) => { const s = document.querySelector("#dl-" + p + " .btns .btn.soon"); return !!s && s.tagName === "SPAN" && s.getAttribute("aria-disabled") === "true" && s === document.querySelector("#dl-" + p + " .btns > :first-child"); }),
        direct: ["mac", "android", "ios"].map((p) => document.querySelector("#dl-" + p + " .btns a").getAttribute("href")),
        version: document.querySelector(".dl-version").textContent, here: [...document.querySelectorAll(".dl.here")].map((n) => n.id),
        imgs: [...document.querySelectorAll("[data-src-l]")].map((i) => i.getAttribute("src")),
      };
    });
    const tag = lang + "/" + os;
    if (lang === "en" && os === "mac") console.log("languages and platforms"), ok(r.missing.length === 0, "every data-t key has Korean: missing " + r.missing.join(", ")), ok(r.unused.length === 0, "no unused Korean keys: " + r.unused.join(", "));
    ok(r.lang === lang, tag + " html lang");
    ok(lang === "ko" ? /여기서/.test(r.h1) && /여기서/.test(r.title) : /Copy here/.test(r.h1), tag + " headline and title in the language");
    const want = { mac: DL + "Nearclip-macOS.zip", win: STORE, android: DL + "Nearclip-Android.apk", ios: "#dl-ios" }[os];
    ok(r.main === want, tag + " main download → " + r.main);
    ok(r.label === (await page.evaluate(([l, o]) => window.SITE_X[l]["dl." + o], [lang, os])), tag + " download label " + r.label);
    ok(r.icon === (os === "win" ? "shopping-bag" : "download") && r.painted, tag + " main download icon " + r.icon);
    ok(r.win.join() === [STORE, DL + "Nearclip-Windows-x64.zip", DL + "Nearclip-Windows-arm64.zip"].join(), tag + " Windows: the Store first, then the ZIPs from GitHub (" + r.win.join(", ") + ")");
    ok(/GitHub/.test(r.or), tag + " Windows says where the direct download comes from: " + r.or);
    ok(r.soon.every(Boolean), tag + " Mac, Android and iPhone lead with their store, coming soon and not clickable (" + r.soon.join(", ") + ")");
    ok(r.direct.join() === [DL + "Nearclip-macOS.zip", DL + "Nearclip-Android.apk", DL + "Nearclip-iOS.ipa"].join(), tag + " …with the direct download under it (" + r.direct.join(", ") + ")");
    ok(/1\.0\.0/.test(r.version), tag + " release version shown: " + r.version);
    ok(r.star.length === 2 && r.star.every((x) => x === REPO_URL + " 1,234"), tag + " the Star buttons go to GitHub with the count (" + r.star.join(", ") + ")");
    ok(r.maker >= 2, tag + " ivlis.kr is linked from the maker block and the footer (" + r.maker + ")");
    ok(r.here.join() === "dl-" + os, tag + " highlights its download card");
    ok(r.imgs.every((s) => s.includes("-" + lang + ".")), tag + " pictures in the language");
    ok(errors.length === 0, tag + " no errors: " + errors.join(" | "));
    await ctx.close();
  }
}

// ---- 3. the live demo, with motion: a copy flies to the other three and lands with "Copied from …"
console.log("live demo");
{
  const { page, ctx, errors } = await open("?lang=en&os=mac");
  await page.click('.tile[data-d="mac"] .t-act');
  await page.waitForTimeout(150);
  ok((await page.locator(".demo-flyer").count()) === 3, "three clips in flight after ⌘C");
  await page.waitForTimeout(2200);
  const rows = await page.evaluate(() => Object.fromEntries([...document.querySelectorAll(".tile")].map((t) => [t.dataset.d, { first: t.querySelector(".t-row b").textContent, from: t.querySelector(".t-row small").textContent, toast: t.querySelector(".t-toast b").textContent }])));
  for (const d of ["win", "android", "ios"]) {
    ok(rows[d].first === "41-1 Yeonmujang-gil, Seoul", d + " got the address (" + rows[d].first + ")");
    ok(rows[d].from.startsWith("MacBook Pro"), d + " says where it came from (" + rows[d].from + ")");
    ok(rows[d].toast === "Copied from MacBook Pro", d + " toast: " + rows[d].toast);
  }
  ok(rows.mac.from.startsWith("This Mac"), "the Mac lists its own copy as This Mac");
  ok((await page.locator(".demo-flyer").count()) === 0, "no clips left in flight");
  // The image: progress first, then the clip
  await page.click('.tile[data-d="android"] .t-act'); // next sample: the code
  await page.waitForTimeout(1900);
  await page.click('.tile[data-d="ios"] .t-act'); // next: the image
  await page.waitForTimeout(700);
  const mid = await page.evaluate(() => [...document.querySelectorAll('.tile:not([data-d="ios"]) .t-toast')].map((t) => ({ b: t.querySelector("b").textContent, bar: !t.querySelector(".bar2").hidden })));
  ok(mid.every((m) => m.b === "Receiving an image from iPhone…" && m.bar), "the others show the image coming with a progress bar");
  await page.waitForTimeout(3200);
  const done = await page.evaluate(() => [...document.querySelectorAll('.tile:not([data-d="ios"])')].map((t) => t.querySelector(".t-row b").textContent));
  ok(done.every((b) => /^Image · /.test(b)), "the image landed everywhere: " + done.join(" / "));
  ok(errors.length === 0, "demo without errors: " + errors.join(" | "));
  await ctx.close();
}
{
  // Reduced motion: no autoplay, no flight, clips land at once (Korean strings)
  const { page, ctx } = await open("?lang=ko&os=mac", { reduce: true });
  await page.waitForTimeout(1600);
  ok((await page.evaluate(() => document.querySelector('.tile[data-d="win"] .t-row b').textContent)) === "내일 10시 회의 자료 공유드립니다", "reduced motion: no autoplay");
  await page.click('.tile[data-d="win"] .t-act');
  const r = await page.evaluate(() => ({ fl: document.querySelectorAll(".demo-flyer").length, mac: document.querySelector('.tile[data-d="mac"] .t-row b').textContent, toast: document.querySelector('.tile[data-d="mac"] .t-toast b').textContent }));
  ok(r.fl === 0 && r.mac === "서울 성동구 연무장길 41-1" && r.toast === "작업실 PC에서 복사됨", "reduced motion: lands at once (" + r.mac + ", " + r.toast + ")");
  await ctx.close();
}

// ---- 4. examples, language menu, film
console.log("examples, language, film");
{
  const { page, ctx, errors } = await open("?lang=en&os=mac");
  await page.click("#pt-2");
  ok(await page.evaluate(() => document.querySelector('#pair-stage img[data-pair="2"]').classList.contains("on") && document.querySelectorAll("#pair-stage img.on").length === 1), "tab 2 shows its picture");
  await page.keyboard.press("ArrowDown");
  ok(await page.evaluate(() => document.activeElement.id === "pt-3" && document.querySelector('#pair-stage img[data-pair="3"]').classList.contains("on")), "arrow keys move to tab 3");
  await page.selectOption("#lang-select", "ko");
  const r = await page.evaluate(() => ({ lang: document.documentElement.lang, h2: document.querySelector("#pairs h2").textContent, film: document.querySelector("#film-video source").getAttribute("src"), demo: document.querySelector('.tile[data-d="win"] .t-name').textContent, url: location.search }));
  ok(r.lang === "ko" && /조합/.test(r.h2), "language menu switches the page");
  ok(r.film === "assets/media/film-ko.mp4", "Korean film on a computer");
  ok(r.demo === "작업실 PC", "the demo follows the language");
  ok(/lang=ko/.test(r.url), "the address remembers the language");
  await page.evaluate(() => document.querySelector("#film").scrollIntoView());
  await page.waitForTimeout(1500);
  const f = await page.evaluate(() => { const v = document.querySelector("#film-video"); return { muted: v.muted, playing: !v.paused, ambient: document.querySelector("#player").classList.contains("ambient") }; });
  ok(f.ambient && f.muted && f.playing, "the film plays muted while on screen");
  await page.click("#film-sound");
  await page.waitForTimeout(400);
  ok(await page.evaluate(() => { const v = document.querySelector("#film-video"); return !v.muted && v.controls; }), "Sound on plays it with sound and controls");
  ok(errors.length === 0, "no errors: " + errors.join(" | "));
  await ctx.close();
}

// ---- 4b. the pairs table, the codes stage and the star count
console.log("pairs table, codes, stars");
{
  const { page, ctx, errors } = await open("?lang=en&os=mac");
  const state = () => page.evaluate(() => ({ mode: document.querySelector("#matrix").dataset.mode, num: document.querySelector("#matrix-num").textContent,
    note: document.querySelector("#matrix-note").textContent, pressed: [...document.querySelectorAll(".seg button")].filter((b) => b.getAttribute("aria-pressed") === "true").map((b) => b.dataset.mode).join(),
    play: document.querySelector("#codes-stage").classList.contains("play") }));
  const cells = await page.evaluate(() => ["nc", "native", "self"].map((c) => document.querySelectorAll("#matrix td." + c).length));
  ok(cells.join() === "12,4,4", "the table has twelve pairs, four of them native, and four same-platform cells (" + cells.join() + ")");
  let s = await state();
  ok(s.mode === "before" && s.num === "4" && s.pressed === "before", "the table starts without Nearclip: 4 / 12");
  ok(!s.play, "the codes stage is still while off screen");
  await page.evaluate(() => document.querySelector("#matrix").scrollIntoView({ block: "center" }));
  await page.waitForTimeout(1700);
  s = await state();
  ok(s.mode === "after" && s.num === "12" && s.pressed === "after", "on screen it fills in by itself: 12 / 12");
  ok(s.note === (await page.evaluate(() => window.SITE_X.en["matrix.note.after"])), "the note follows: " + s.note);
  await page.click('.seg button[data-mode="before"]');
  s = await state();
  ok(s.mode === "before" && s.num === "4" && s.pressed === "before", "the switch goes back to 4 / 12");
  await page.evaluate(() => document.querySelector("#codes-stage").scrollIntoView({ block: "center", behavior: "instant" }));
  await page.waitForTimeout(250);
  s = await state();
  const ask = await page.evaluate(() => +getComputedStyle(document.querySelector("#codes-stage .capsule.ask")).opacity);
  ok(s.play && ask > 0.9, "on screen the codes stage plays, starting on the question (opacity " + ask.toFixed(2) + ")");
  await page.evaluate(() => scrollTo({ top: 0, behavior: "instant" }));
  await page.waitForTimeout(250);
  ok(!(await state()).play, "it stops once it's off screen");
  ok(errors.length === 0, "no errors: " + errors.join(" | "));
  await ctx.close();
}
{
  const { page, ctx } = await open("?lang=ko&os=mac", { reduce: true });
  await page.evaluate(() => document.querySelector("#codes-stage").scrollIntoView({ block: "center" }));
  await page.waitForTimeout(500);
  const r = await page.evaluate(() => ({ mode: document.querySelector("#matrix").dataset.mode, num: document.querySelector("#matrix-num").textContent, play: document.querySelector("#codes-stage").classList.contains("play"),
    ask: +getComputedStyle(document.querySelector("#codes-stage .capsule.ask")).opacity, notif: +getComputedStyle(document.querySelector("#codes-stage .notif")).opacity }));
  ok(r.mode === "after" && r.num === "12", "reduced motion: the table shows all twelve at once");
  ok(!r.play && r.ask === 1 && r.notif === 1, "reduced motion: the codes stage holds the text and the question");
  await ctx.close();
}
{
  const { page, ctx } = await open("?lang=en&os=mac", { stars: 3 });
  await page.waitForTimeout(300);
  ok(await page.evaluate(() => [...document.querySelectorAll(".star-count")].every((n) => n.hidden)), "a handful of stars isn't shown as a number");
  await ctx.close();
}

// ---- 5. phones: the vertical film, nothing wider than the screen, in both languages and themes
console.log("phones");
for (const [w, h] of [[360, 780], [390, 844]]) {
  for (const lang of ["en", "ko"]) {
    const { page, ctx, errors } = await open("?lang=" + lang + "&os=ios", { viewport: { width: w, height: h }, mobile: true, scheme: lang === "ko" ? "dark" : "light" });
    await page.evaluate(() => document.querySelectorAll(".reveal").forEach((n) => n.classList.add("in")));
    const r = await page.evaluate(() => ({ over: document.documentElement.scrollWidth - innerWidth, film: document.querySelector("#film-video source").getAttribute("src"), vertical: document.querySelector("#player").classList.contains("vertical"),
      store: ((b) => b.scrollWidth <= b.clientWidth && getComputedStyle(b.querySelector(".long")).display !== "none")(document.querySelector("#dl-win .btn.ink")),
      star: ((a) => a.getBoundingClientRect().right <= innerWidth && !!a.querySelector(".ico svg path"))(document.querySelector(".star-mini")) }));
    ok(r.over <= 0, w + "px " + lang + ": no sideways scrolling (" + r.over + "px)");
    ok(r.vertical && r.film === "assets/media/film-" + lang + "-v.mp4", w + "px " + lang + ": the 9:16 film");
    ok(r.store, w + "px " + lang + ": the whole Microsoft Store label fits its button");
    ok(r.star, w + "px " + lang + ": the Star button fits the header");
    ok(errors.length === 0, w + "px " + lang + ": no errors " + errors.join(" | "));
    await ctx.close();
  }
}

// ---- 5b. computers: the download list gives the Windows button room for its whole label at every width
console.log("the Store button");
for (const [w, lang] of [[1100, "en"], [1100, "ko"], [1440, "en"], [1440, "ko"], [1000, "en"], [1000, "ko"]]) {
  const { page, ctx } = await open("?lang=" + lang + "&os=win", { viewport: { width: w, height: 900 } });
  const r = await page.evaluate(() => { const b = document.querySelector("#dl-win .btn.ink"); return { fits: b.scrollWidth <= b.clientWidth, long: getComputedStyle(b.querySelector(".long")).display !== "none" }; });
  ok(r.fits && r.long, w + "px " + lang + ": the whole Store label fits its button (" + (r.long ? "long" : "short") + ")");
  await ctx.close();
}

// ---- 6. the other pages
for (const file of ["privacy.html"]) {
  const { page, ctx, errors } = await open(file);
  ok((await page.locator("#ko h1").textContent()) === "개인정보 처리방침", file + " has the Korean policy");
  ok(errors.length === 0, file + " no errors " + errors.join(" | "));
  await ctx.close();
}

await browser.close();
server.close();
console.log((failures ? "FAILED " + failures : "passed") + " · " + checks + " checks");
process.exit(failures ? 1 : 0);
