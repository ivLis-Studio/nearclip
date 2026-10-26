// Page behaviour: language, platform, icons, the live demo, the pairs table, examples, film, the code and image toasts,
// release info and the GitHub star count.
(function () {
  "use strict";
  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return [].slice.call((r || document).querySelectorAll(s)); };
  var LANGS = ["en", "ko"];
  var REPO = "ivLis-Studio/nearclip";
  var DL = "https://github.com/" + REPO + "/releases/latest/download/";
  // Windows leads with the Microsoft Store; its ZIPs stay in the download list as the direct download.
  var STORE = { win: "https://apps.microsoft.com/detail/9PNQ3Z9S83QS" };
  var ASSET = { mac: "Nearclip-macOS.zip", android: "Nearclip-Android.apk" };
  // The star count shows next to the Star buttons once there's a real crowd behind it.
  var STAR_MIN = 10;
  var stored = function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } };
  var keep = function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} };
  var calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
  var onScreen = function (node, threshold, fn) { new IntersectionObserver(function (es) { fn(es[0].isIntersecting); }, { threshold: threshold }).observe(node); };

  // ---- icons
  function paint(n) { n.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' + (window.ICONS[n.dataset.i] || "") + "</svg>"; }
  $$("[data-i]").forEach(paint);

  // ---- language: ?lang= → saved → browser → English
  var params = new URLSearchParams(location.search);
  var browserLang = (navigator.languages || [navigator.language || "en"]).map(function (l) { return String(l).slice(0, 2).toLowerCase(); })
    .filter(function (l) { return LANGS.indexOf(l) >= 0; })[0];
  var lang = [params.get("lang"), stored("nc.lang"), browserLang, "en"].filter(function (l) { return LANGS.indexOf(l) >= 0; })[0];
  var X = function (k) {
    var a = [].slice.call(arguments, 1);
    var s = (window.SITE_X[lang] || {})[k] || window.SITE_X.en[k] || k;
    return s.replace(/%@/g, function () { return a.shift(); });
  };

  // ---- platform: ?os= → this device
  function systemOS() {
    var ua = navigator.userAgent || "", p = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    if (/iPhone|iPad|iPod/.test(ua) || (/Mac/.test(p) && navigator.maxTouchPoints > 1)) return "ios";
    if (/Android/i.test(ua)) return "android";
    if (/Win/i.test(p) || /Windows/.test(ua)) return "win";
    if (/Mac/i.test(p) || /Mac OS X/.test(ua)) return "mac";
    return "other";
  }
  var os = ["mac", "win", "android", "ios", "other"].indexOf(params.get("os")) >= 0 ? params.get("os") : systemOS();

  var originals = $$("[data-t]").map(function (n) { return [n, n.innerHTML]; });
  var altOriginals = $$("[data-t-alt]").map(function (n) { return [n, n.getAttribute("alt")]; });

  // ---- live demo
  var demo = window.NearclipDemo.mount($("#demo"), { strings: window.DEMO[lang], auto: true, live: $("#demo-live") });

  function applyLang(l) {
    lang = l;
    document.documentElement.lang = l;
    var dict = l === "en" ? {} : window.SITE_I18N[l] || {};
    originals.forEach(function (p) { var k = p[0].dataset.t; p[0].innerHTML = k in dict ? dict[k] : p[1]; });
    altOriginals.forEach(function (p) { var k = p[0].dataset.tAlt; p[0].setAttribute("alt", k in dict ? dict[k] : p[1]); });
    $$("[data-src-l]").forEach(function (img) { var want = img.dataset.srcL.replace("%L", l); if (img.getAttribute("src") !== want) img.setAttribute("src", want); });
    $$("[data-i]").forEach(function (n) { if (!n.firstChild) paint(n); });
    var meta = window.SITE_META[l] || window.SITE_META.en;
    document.title = meta.title;
    $('meta[name="description"]').setAttribute("content", meta.desc);
    $("#lang-select").value = l;
    $("#play").setAttribute("aria-label", X("film.play"));
    demo.setStrings(window.DEMO[l]);
    renderPlatform();
    renderRelease();
    renderStars();
    renderMatrix();
    setFilm();
    resetToast();
  }
  $("#lang-select").addEventListener("change", function (e) {
    keep("nc.lang", e.target.value);
    var u = new URL(location.href);
    u.searchParams.set("lang", e.target.value);
    history.replaceState(null, "", u);
    applyLang(e.target.value);
  });

  // ---- download buttons follow this device: the Store for Windows, the latest release for Mac and Android
  function assetURL(name) {
    var a = release && release.assets.filter(function (x) { return x.name === name; })[0];
    return a ? a.browser_download_url : DL + name;
  }
  function mainURL() { return STORE[os] || (ASSET[os] ? assetURL(ASSET[os]) : os === "ios" ? "#dl-ios" : "#download"); }
  function renderPlatform() {
    var icon = STORE[os] ? "shopping-bag" : "download";
    $$(".dl-main").forEach(function (a) {
      a.setAttribute("href", mainURL());
      var n = a.querySelector(".ico");
      if (n.dataset.i !== icon) { n.dataset.i = icon; paint(n); }
    });
    $$(".dl-main-label").forEach(function (n) { n.textContent = X("dl." + os); });
    $$("[data-plat]").forEach(function (n) { n.classList.toggle("here", n.dataset.plat === os); });
    $$("[data-asset]").forEach(function (a) { a.setAttribute("href", assetURL(a.dataset.asset)); });
  }

  // ---- GitHub: the latest release (version, date, asset links) and the star count. Everything works without them.
  var release = null, stars = null;
  function renderRelease() {
    if (!release) return;
    var v = release.tag_name.replace(/^v/, "");
    var date = new Date(release.published_at);
    var when = isNaN(date) ? "" : date.toLocaleDateString(lang === "ko" ? "ko-KR" : "en-US", { year: "numeric", month: "long", day: "numeric" });
    $$(".dl-version").forEach(function (n) { n.textContent = X("dl.version", v); });
    $$(".dl-version-long").forEach(function (n) { n.textContent = X("dl.latest", v, when); });
  }
  function renderStars() {
    if (stars == null || stars < STAR_MIN) return;
    var shown = stars.toLocaleString(lang === "ko" ? "ko-KR" : "en-US");
    $$(".star-count").forEach(function (n) { n.textContent = shown; n.hidden = false; });
    $$(".star-mini, .star-cta").forEach(function (a) { a.setAttribute("title", X("star.count", shown)); });
  }
  var gh = function (path) {
    return fetch("https://api.github.com/repos/" + REPO + path, { headers: { Accept: "application/vnd.github+json" } })
      .then(function (r) { return r.ok ? r.json() : null; });
  };
  gh("/releases/latest").then(function (j) { if (j && j.tag_name) { release = j; renderRelease(); renderPlatform(); } }).catch(function () {});
  gh("").then(function (j) { if (j && typeof j.stargazers_count === "number") { stars = j.stargazers_count; renderStars(); } }).catch(function () {});

  // ---- header rule once the page moves
  var bar = $("#bar");
  addEventListener("scroll", function () { bar.classList.toggle("scrolled", scrollY > 8); }, { passive: true });

  // ---- the pairs table: four of twelve without Nearclip, twelve with it. The first time it's on screen it fills in by
  // itself (not with reduced motion); the switch is the visitor's after that.
  var matrix = $("#matrix"), modes = $$(".seg button"), matrixTouched = false;
  $$("td.nc", matrix).forEach(function (td, i) { td.style.setProperty("--i", i); });
  function renderMatrix() {
    var mode = matrix.dataset.mode;
    $("#matrix-num").textContent = mode === "after" ? "12" : "4";
    $("#matrix-note").textContent = X("matrix.note." + mode);
  }
  function setMode(mode) {
    matrix.dataset.mode = mode;
    modes.forEach(function (b) { b.setAttribute("aria-pressed", String(b.dataset.mode === mode)); });
    renderMatrix();
  }
  modes.forEach(function (b) { b.addEventListener("click", function () { matrixTouched = true; setMode(b.dataset.mode); }); });
  if (!calm) {
    setMode("before");
    var filled = false;
    onScreen(matrix, 0.55, function (seen) {
      if (!seen || filled) return;
      filled = true;
      setTimeout(function () { if (!matrixTouched) setMode("after"); }, 900);
    });
  }

  // ---- examples: tabs with arrow keys; they turn by themselves while on screen until someone picks one
  var ptabs = $$(".pair-tab"), stage = $("#pair-stage"), pairTimer = 0, pairAuto = !calm, pairSeen = false;
  function selectPair(tab, focus) {
    ptabs.forEach(function (t) { var on = t === tab; t.setAttribute("aria-selected", String(on)); t.tabIndex = on ? 0 : -1; t.classList.remove("timing"); });
    stage.setAttribute("aria-labelledby", tab.id);
    $$("img", stage).forEach(function (img) { img.classList.toggle("on", img.dataset.pair === tab.dataset.pair); });
    if (focus) tab.focus();
  }
  function pairTick() {
    clearTimeout(pairTimer);
    ptabs.forEach(function (t) { t.classList.remove("timing"); });
    if (!pairAuto || !pairSeen) return;
    var i = ptabs.findIndex(function (t) { return t.getAttribute("aria-selected") === "true"; });
    void ptabs[i].offsetWidth;
    ptabs[i].classList.add("timing");
    pairTimer = setTimeout(function () { selectPair(ptabs[(i + 1) % ptabs.length]); pairTick(); }, 5200);
  }
  function takeOver() { pairAuto = false; clearTimeout(pairTimer); ptabs.forEach(function (t) { t.classList.remove("timing"); }); }
  ptabs.forEach(function (t, i) {
    t.addEventListener("click", function () { takeOver(); selectPair(t); });
    t.addEventListener("keydown", function (e) {
      var d = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
      if (!d) return;
      e.preventDefault();
      takeOver();
      selectPair(ptabs[(i + d + ptabs.length) % ptabs.length], true);
    });
  });
  onScreen(stage, 0.4, function (seen) { pairSeen = seen; if (seen) pairTick(); else { clearTimeout(pairTimer); ptabs.forEach(function (t) { t.classList.remove("timing"); }); } });

  // ---- film: muted and looping while on screen (not with reduced motion or Data Saver); Sound on starts it over.
  // Phones held upright get the 9:16 cut.
  var video = $("#film-video"), player = $("#player"), pauseButton = $("#film-pause");
  var quiet = calm || !!(navigator.connection && navigator.connection.saveData);
  var upright = matchMedia("(max-width: 640px) and (orientation: portrait)");
  var ambient = false, held = false, inView = false;
  function setPauseButton() {
    var icon = pauseButton.querySelector(".ico"), want = video.paused ? "play" : "pause";
    if (icon.dataset.i !== want) { icon.dataset.i = want; paint(icon); }
    pauseButton.setAttribute("aria-label", X(video.paused ? "film.resume" : "film.pause"));
  }
  function quietPlay() {
    var p = video.play();
    if (p && p.catch) p.catch(function (e) { if (e && e.name === "NotAllowedError") { ambient = false; player.classList.remove("ambient"); } });
  }
  function enterAmbient() {
    ambient = !quiet; held = false;
    video.muted = true; video.loop = true; video.controls = false;
    player.classList.remove("playing");
    player.classList.toggle("ambient", ambient);
    if (ambient && inView) quietPlay();
    setPauseButton();
  }
  function playWithSound() {
    ambient = false; held = false;
    player.classList.remove("ambient"); player.classList.add("playing");
    video.loop = false; video.muted = false; video.controls = true;
    try { video.currentTime = 0; } catch (e) {}
    var p = video.play();
    if (p && p.catch) p.catch(function () {});
  }
  function setFilm() {
    var name = (lang === "ko" ? "ko" : "en") + (upright.matches ? "-v" : "");
    var want = "assets/media/film-" + name + ".mp4", src = video.querySelector("source");
    player.classList.toggle("vertical", upright.matches);
    $("#film-file").setAttribute("href", want);
    if (src.getAttribute("src") !== want) {
      src.setAttribute("src", want);
      video.poster = "assets/media/poster-" + name + ".webp";
      video.load();
      enterAmbient();
    }
    setPauseButton();
  }
  (upright.addEventListener ? upright.addEventListener.bind(upright, "change") : upright.addListener.bind(upright))(setFilm);
  onScreen(player, 0.35, function (seen) {
    inView = seen;
    if (!ambient || held) return;
    if (inView) quietPlay(); else video.pause();
  });
  $("#play").addEventListener("click", playWithSound);
  $("#film-sound").addEventListener("click", playWithSound);
  video.addEventListener("click", function () { if (ambient) playWithSound(); });
  pauseButton.addEventListener("click", function () { if (video.paused) { held = false; quietPlay(); } else { held = true; video.pause(); } });
  video.addEventListener("play", function () { if (!ambient) { video.controls = true; player.classList.add("playing"); } setPauseButton(); });
  video.addEventListener("pause", setPauseButton);

  // ---- verification codes: the text arrives, the code crosses over, the computer asks "Copy it?" — on loop while on
  // screen. With reduced motion the stage holds the question still.
  var codes = $("#codes-stage");
  if (!calm) onScreen(codes, 0.4, function (seen) { codes.classList.toggle("play", seen); });

  // ---- the image-progress toast: announced, counting up, then "Copied from iPhone"
  var td = $("#toast-demo"), tdRun = 0, tdTimer = 0, tdInView = false;
  function finishToast() {
    td.classList.add("done");
    $("#toast-title").textContent = X("toast.copied", "iPhone");
    $("#toast-sub").textContent = X("toast.image", "8.4");
    $("#toast-bar").style.width = "100%";
  }
  function runToast() {
    var run = ++tdRun, total = 8.4, sub = $("#toast-sub"), bar2 = $("#toast-bar");
    clearTimeout(tdTimer);
    td.classList.remove("done");
    $("#toast-title").textContent = X("toast.receiving", "iPhone");
    sub.textContent = X("toast.preparing");
    bar2.style.width = "0%";
    var t0 = performance.now() + 900, dur = 3400;
    function step(now) {
      if (run !== tdRun) return;
      var p = Math.max(0, Math.min(1, (now - t0) / dur));
      if (now >= t0) { sub.textContent = (p * total).toFixed(1) + " / " + total.toFixed(1) + " MB"; bar2.style.width = (p * 100).toFixed(1) + "%"; }
      if (p < 1) { requestAnimationFrame(step); return; }
      finishToast();
      tdTimer = setTimeout(function () { if (tdInView && run === tdRun) runToast(); }, 2800);
    }
    requestAnimationFrame(step);
  }
  function resetToast() { tdRun++; clearTimeout(tdTimer); if (calm || !tdInView) finishToast(); else runToast(); }
  onScreen(td, 0.5, function (seen) {
    var was = tdInView;
    tdInView = seen;
    if (tdInView && !was && !calm) runToast();
  });

  applyLang(lang);
})();
