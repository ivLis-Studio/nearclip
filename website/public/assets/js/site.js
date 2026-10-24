// Page behaviour: language, platform, icons, the live demo, examples, film, image-progress toast, release info.
(function () {
  "use strict";
  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return [].slice.call((r || document).querySelectorAll(s)); };
  var LANGS = ["en", "ko"];
  var REPO = "ivLis-Studio/nearclip";
  var DL = "https://github.com/" + REPO + "/releases/latest/download/";
  var stored = function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } };
  var keep = function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} };
  var calm = matchMedia("(prefers-reduced-motion: reduce)").matches;

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

  // ---- platform: ?os= → this device. Windows on Arm gets the Arm64 build first.
  function systemOS() {
    var ua = navigator.userAgent || "", p = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    if (/iPhone|iPad|iPod/.test(ua) || (/Mac/.test(p) && navigator.maxTouchPoints > 1)) return "ios";
    if (/Android/i.test(ua)) return "android";
    if (/Win/i.test(p) || /Windows/.test(ua)) return "win";
    if (/Mac/i.test(p) || /Mac OS X/.test(ua)) return "mac";
    return "other";
  }
  var os = ["mac", "win", "android", "ios", "other"].indexOf(params.get("os")) >= 0 ? params.get("os") : systemOS();
  var arm = false;

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

  // ---- download buttons follow this device
  function mainAsset() { return os === "mac" ? "Nearclip-macOS.zip" : os === "win" ? (arm ? "Nearclip-Windows-arm64.zip" : "Nearclip-Windows-x64.zip") : os === "android" ? "Nearclip-Android.apk" : null; }
  function assetURL(name) {
    var a = release && release.assets.filter(function (x) { return x.name === name; })[0];
    return a ? a.browser_download_url : DL + name;
  }
  function renderPlatform() {
    var asset = mainAsset();
    $$(".dl-main").forEach(function (a) { a.setAttribute("href", asset ? assetURL(asset) : os === "ios" ? "#dl-ios" : "#download"); });
    $$(".dl-main-label").forEach(function (n) { n.textContent = X("dl." + os); });
    $$("[data-plat]").forEach(function (n) { n.classList.toggle("here", n.dataset.plat === os); });
    $$("[data-asset]").forEach(function (a) { a.setAttribute("href", assetURL(a.dataset.asset)); });
  }

  // ---- latest release from GitHub: version and date (the links work without it)
  var release = null;
  function renderRelease() {
    if (!release) return;
    var v = release.tag_name.replace(/^v/, "");
    var date = new Date(release.published_at);
    var when = isNaN(date) ? "" : date.toLocaleDateString(lang === "ko" ? "ko-KR" : "en-US", { year: "numeric", month: "long", day: "numeric" });
    $$(".dl-version").forEach(function (n) { n.textContent = X("dl.version", v); });
    $$(".dl-version-long").forEach(function (n) { n.textContent = X("dl.latest", v, when); });
  }
  fetch("https://api.github.com/repos/" + REPO + "/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (j) { if (j && j.tag_name) { release = j; renderRelease(); renderPlatform(); } })
    .catch(function () {});
  // Only a real Windows PC asks for its architecture (a ?os=win preview on another computer keeps x64).
  if (os === "win" && systemOS() === "win" && navigator.userAgentData && navigator.userAgentData.getHighEntropyValues) {
    navigator.userAgentData.getHighEntropyValues(["architecture"]).then(function (v) { arm = v.architecture === "arm"; renderPlatform(); }).catch(function () {});
  }

  // ---- header border on scroll, reveal on scroll
  var bar = $("#bar");
  addEventListener("scroll", function () { bar.classList.toggle("scrolled", scrollY > 8); }, { passive: true });
  var io = new IntersectionObserver(function (es) {
    es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
  }, { rootMargin: "0px 0px -8% 0px" });
  $$(".reveal").forEach(function (n) { io.observe(n); });

  // ---- examples: tabs with arrow keys; they turn by themselves while on screen until someone picks one
  var ptabs = $$(".pair-tab"), stage = $("#pair-stage"), pairTimer = 0, pairAuto = !calm, pairSeen = false;
  function selectPair(tab, focus) {
    ptabs.forEach(function (t) { var on = t === tab; t.setAttribute("aria-selected", String(on)); t.tabIndex = on ? 0 : -1; });
    stage.setAttribute("aria-labelledby", tab.id);
    $$("img", stage).forEach(function (img) { img.classList.toggle("on", img.dataset.pair === tab.dataset.pair); });
    if (focus) tab.focus();
  }
  function pairTick() {
    clearTimeout(pairTimer);
    if (!pairAuto || !pairSeen) return;
    pairTimer = setTimeout(function () {
      var i = ptabs.findIndex(function (t) { return t.getAttribute("aria-selected") === "true"; });
      selectPair(ptabs[(i + 1) % ptabs.length]);
      pairTick();
    }, 5200);
  }
  ptabs.forEach(function (t, i) {
    t.addEventListener("click", function () { pairAuto = false; clearTimeout(pairTimer); selectPair(t); });
    t.addEventListener("keydown", function (e) {
      var d = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
      if (!d) return;
      e.preventDefault();
      pairAuto = false; clearTimeout(pairTimer);
      selectPair(ptabs[(i + d + ptabs.length) % ptabs.length], true);
    });
  });
  new IntersectionObserver(function (es) { pairSeen = es[0].isIntersecting; if (pairSeen) pairTick(); else clearTimeout(pairTimer); }, { threshold: 0.4 }).observe(stage);

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
  new IntersectionObserver(function (es) {
    inView = es[0].isIntersecting;
    if (!ambient || held) return;
    if (inView) quietPlay(); else video.pause();
  }, { threshold: 0.35 }).observe(player);
  $("#play").addEventListener("click", playWithSound);
  $("#film-sound").addEventListener("click", playWithSound);
  video.addEventListener("click", function () { if (ambient) playWithSound(); });
  pauseButton.addEventListener("click", function () { if (video.paused) { held = false; quietPlay(); } else { held = true; video.pause(); } });
  video.addEventListener("play", function () { if (!ambient) { video.controls = true; player.classList.add("playing"); } setPauseButton(); });
  video.addEventListener("pause", setPauseButton);

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
  new IntersectionObserver(function (es) {
    var was = tdInView;
    tdInView = es[0].isIntersecting;
    if (tdInView && !was && !calm) runToast();
  }, { threshold: 0.5 }).observe(td);

  applyLang(lang);
})();

