// Live demo for the Nearclip site: four devices, one clipboard. A copy on any of them flies to the other three, the way
// the apps do it — straight from device to device, with "Copied from …" on arrival and a progress bar for big images.
// NearclipDemo.mount(element, { strings, auto, live, still }) → { setStrings }
(function () {
  "use strict";
  var DEVS = ["mac", "win", "android", "ios"];
  var DEV_ICON = { mac: "laptop", win: "monitor", android: "smartphone", ios: "smartphone" };
  var KIND_ICON = { text: "type", link: "link", code: "hash", image: "image", color: "palette" };
  // The autoplay crosses ecosystems on every hop, like the film: Mac → the rest, then Android, iPhone, Windows…
  var AUTO = [["mac", 0], ["android", 1], ["ios", 2], ["win", 3], ["mac", 4], ["android", 5]];
  var SVGNS = "http://www.w3.org/2000/svg";

  function ic(name) { return '<i class="ico" aria-hidden="true"><svg viewBox="0 0 24 24">' + ((window.ICONS || {})[name] || "") + "</svg></i>"; }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function fmt(s) { var a = [].slice.call(arguments, 1); return String(s).replace(/%@/g, function () { return a.shift(); }); }
  function actHTML(d) {
    if (d === "mac") return '<button type="button" class="t-act"><span class="kc">⌘</span><span class="kc">C</span></button>';
    if (d === "win") return '<button type="button" class="t-act"><span class="kc">Ctrl</span><span class="kc">C</span></button>';
    return '<button type="button" class="t-act pill">' + ic(d === "android" ? "send" : "clipboard-paste") + '<span class="t-actlabel"></span></button>';
  }
  function curve(a, b, bend) {
    var dx = b.x - a.x, dy = b.y - a.y;
    return { x: (a.x + b.x) / 2 - dy * bend, y: (a.y + b.y) / 2 + dx * bend };
  }
  function qpt(a, c, b, t) {
    var u = 1 - t;
    return { x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y };
  }

  function mount(root, opts) {
    var S = opts.strings;
    var still = opts.still || null;
    var reduce = !!still || matchMedia("(prefers-reduced-motion: reduce)").matches;
    var live = opts.live || null;
    var tiles = {}, lists = {};
    var uid = 0, next = 0, autoOn = !!opts.auto && !reduce, autoTimer = 0, autoStep = 0, inView = false;

    root.classList.add("demo");
    root.setAttribute("role", "group");
    var svg = document.createElementNS(SVGNS, "svg");
    svg.setAttribute("class", "mesh");
    svg.setAttribute("aria-hidden", "true");
    root.appendChild(svg);
    var meshLines = document.createElementNS(SVGNS, "g");
    svg.appendChild(meshLines);

    DEVS.forEach(function (d) {
      var t = document.createElement("div");
      t.className = "tile";
      t.dataset.d = d;
      t.setAttribute("role", "group");
      t.innerHTML = '<div class="t-head"><span class="dev">' + ic(DEV_ICON[d]) + '</span><b class="t-name"></b><small class="t-plat"></small></div>' +
        '<ul class="t-list"></ul>' +
        '<div class="t-foot"><span class="t-status"></span>' + actHTML(d) + "</div>" +
        '<div class="t-toast" aria-hidden="true"><i class="t-ic"></i><span><b></b><small></small><span class="bar2" hidden><i></i></span></span></div>';
      root.appendChild(t);
      tiles[d] = { el: t, list: t.querySelector(".t-list"), toast: t.querySelector(".t-toast"), act: t.querySelector(".t-act"), token: 0, hide: 0, status: 0 };
      lists[d] = S.seed.map(function (x, i) { return { id: ++uid, s: i, seed: true, from: x.from, ago: x.ago }; });
      tiles[d].act.addEventListener("click", function () {
        stopAuto();
        send(d, next, true);
        next = (next + 1) % S.samples.length;
      });
    });

    function source(it) { return it.seed ? S.seed[it.s] : S.samples[it.s]; }
    function title(src) { return src.kind === "image" ? S.image + " · " + src.meta : src.text; }
    function rowHTML(it, d) {
      var src = source(it), k = src.kind;
      var cls = "t-ic" + (k === "link" ? " link" : k === "image" ? " img" : k === "color" ? " color" : "");
      var who = it.from === d ? S.self[d] : S.names[it.from];
      var when = it.ago ? fmt(S.minAgo, it.ago) : S.justNow;
      var glyph = k === "image" || k === "color" ? "" : ic(KIND_ICON[k]);
      return '<li class="t-row" data-id="' + it.id + '"><i class="' + cls + '">' + glyph + "</i><span><b" + (k === "code" || k === "color" ? ' class="mono"' : "") + ">" +
        esc(title(src)) + "</b><small>" + esc(who + " · " + when) + "</small></span></li>";
    }
    function renderList(d, fresh) {
      var box = tiles[d].list;
      box.innerHTML = lists[d].slice(0, 4).map(function (it) { return rowHTML(it, d); }).join("");
      if (fresh == null || reduce) return;
      var row = box.querySelector('[data-id="' + fresh + '"]');
      if (!row) return;
      row.classList.add("new");
      setTimeout(function () { row.classList.add("fade"); row.classList.remove("new"); }, 1500);
    }
    function applyStrings() {
      root.setAttribute("aria-label", S.label);
      DEVS.forEach(function (d) {
        var t = tiles[d];
        t.el.querySelector(".t-name").textContent = S.names[d];
        t.el.querySelector(".t-plat").textContent = S.plat[d];
        t.el.querySelector(".t-status").textContent = S.connected;
        var lab = t.el.querySelector(".t-actlabel");
        if (lab) lab.textContent = S.act[d];
        t.act.setAttribute("aria-label", S.actLabel[d]);
        t.el.setAttribute("aria-label", S.names[d] + " · " + S.plat[d]);
        renderList(d);
      });
    }
    function center(d) {
      var r = tiles[d].el.getBoundingClientRect(), o = root.getBoundingClientRect();
      return { x: r.left - o.left + r.width / 2, y: r.top - o.top + r.height / 2 };
    }
    function layout() {
      var o = root.getBoundingClientRect();
      svg.setAttribute("viewBox", "0 0 " + o.width + " " + o.height);
      var html = "";
      for (var i = 0; i < 4; i++) for (var j = i + 1; j < 4; j++) {
        var a = center(DEVS[i]), b = center(DEVS[j]);
        html += '<line x1="' + a.x.toFixed(1) + '" y1="' + a.y.toFixed(1) + '" x2="' + b.x.toFixed(1) + '" y2="' + b.y.toFixed(1) + '"/>';
      }
      meshLines.innerHTML = html;
    }
    function setStatus(d, text, ms) {
      var t = tiles[d], n = t.el.querySelector(".t-status");
      n.textContent = text;
      clearTimeout(t.status);
      t.status = setTimeout(function () { n.textContent = S.connected; }, ms);
    }
    function showToast(d, from, head, sub, progress) {
      var t = tiles[d], el = t.toast;
      t.token++;
      el.querySelector(".t-ic").innerHTML = ic(DEV_ICON[from]);
      el.querySelector("b").textContent = head;
      el.querySelector("small").textContent = sub;
      var bar = el.querySelector(".bar2");
      bar.hidden = !progress;
      bar.firstChild.style.width = "0%";
      el.classList.add("show");
      clearTimeout(t.hide);
      if (!progress && !still) t.hide = setTimeout(function () { el.classList.remove("show"); }, 2000);
      return t.token;
    }
    function arrive(to, from, it, src) {
      lists[to].unshift({ id: it.id, s: it.s, seed: false, from: from, ago: 0 });
      renderList(to, it.id);
      var t = tiles[to];
      if (!still) {
        t.el.classList.add("hit");
        setTimeout(function () { t.el.classList.remove("hit"); }, 900);
      }
      showToast(to, from, fmt(S.copiedFrom, S.names[from]), title(src), false);
    }
    // A big image is announced before it is encoded, so the others show progress right away; the clip lands when it's in.
    function receiving(to, from, it, src, i) {
      var t = tiles[to], total = src.size;
      var token = showToast(to, from, fmt(S.receiving, S.names[from]), "0.0 / " + total.toFixed(1) + " MB", true);
      var bar = t.toast.querySelector(".bar2 i"), small = t.toast.querySelector("small");
      var start = performance.now() + 350 + i * 140, dur = reduce ? 0 : 1900 + i * 260;
      function step(now) {
        var p = dur ? Math.max(0, Math.min(1, (now - start) / dur)) : 1;
        if (t.token === token) {
          bar.style.width = (p * 100).toFixed(1) + "%";
          small.textContent = (p * total).toFixed(1) + " / " + total.toFixed(1) + " MB";
        }
        if (p < 1) requestAnimationFrame(step); else arrive(to, from, it, src);
      }
      requestAnimationFrame(step);
    }
    function beam(a, c, b, cls) {
      var p = document.createElementNS(SVGNS, "path");
      p.setAttribute("d", "M" + a.x.toFixed(1) + " " + a.y.toFixed(1) + " Q" + c.x.toFixed(1) + " " + c.y.toFixed(1) + " " + b.x.toFixed(1) + " " + b.y.toFixed(1));
      p.setAttribute("class", cls);
      svg.appendChild(p);
      return p;
    }
    function flyer(src) {
      var f = document.createElement("div");
      f.className = "demo-flyer";
      f.setAttribute("aria-hidden", "true");
      f.innerHTML = '<i class="t-ic">' + ic(KIND_ICON[src.kind]) + "</i><span>" + esc(src.kind === "image" ? S.image : src.text) + "</span>";
      root.appendChild(f);
      return f;
    }
    function fly(from, to, it, src, i) {
      var img = src.kind === "image";
      if (img) receiving(to, from, it, src, i);
      if (reduce) { if (!img) arrive(to, from, it, src); return; }
      var a = center(from), b = center(to), c = curve(a, b, 0.2);
      var p = beam(a, c, b, "go");
      setTimeout(function () { p.remove(); }, 1400);
      var f = flyer(src), w = f.offsetWidth, h = f.offsetHeight, frames = [], N = 16;
      for (var k = 0; k <= N; k++) {
        var q = qpt(a, c, b, k / N), sc = k === 0 ? 0.55 : k === N ? 0.8 : 1;
        frames.push({ transform: "translate(" + (q.x - w / 2).toFixed(1) + "px," + (q.y - h / 2).toFixed(1) + "px) scale(" + sc + ")", opacity: k === 0 || k === N ? 0 : 1 });
      }
      var anim = f.animate(frames, { duration: 950 + i * 110, delay: i * 80, easing: "cubic-bezier(.45,.05,.3,1)", fill: "both" });
      anim.onfinish = function () { f.remove(); if (!img) arrive(to, from, it, src); };
    }
    function send(from, s) {
      var src = S.samples[s], it = { id: ++uid, s: s, seed: false, from: from, ago: 0 }, t = tiles[from];
      if (!reduce) {
        t.act.classList.add("down");
        t.el.classList.add("send");
        setTimeout(function () { t.act.classList.remove("down"); t.el.classList.remove("send"); }, 170);
      }
      lists[from].unshift(it);
      renderList(from, it.id);
      setStatus(from, S.sent, 2000);
      if (live) live.textContent = fmt(S.announce, S.names[from], src.kind === "image" ? S.image : src.text);
      DEVS.filter(function (d) { return d !== from; }).forEach(function (d, i) { fly(from, d, it, src, i); });
    }

    // ---- autoplay while on screen, until the visitor takes over (never with reduced motion)
    function tick() {
      autoTimer = 0;
      if (!autoOn || !inView || document.hidden) return;
      var step = AUTO[autoStep % AUTO.length];
      autoStep++;
      send(step[0], step[1]);
      next = (step[1] + 1) % S.samples.length;
      autoTimer = setTimeout(tick, S.samples[step[1]].kind === "image" ? 4400 : 3300);
    }
    function startAuto(delay) { if (autoOn && !autoTimer) autoTimer = setTimeout(tick, delay); }
    function stopAuto() { autoOn = false; clearTimeout(autoTimer); autoTimer = 0; }
    if ("IntersectionObserver" in window) {
      new IntersectionObserver(function (es) { inView = es[0].isIntersecting; if (inView) startAuto(1100); }, { threshold: 0.35 }).observe(root);
    }
    document.addEventListener("visibilitychange", function () { if (!document.hidden && inView) startAuto(800); });

    applyStrings();
    layout();
    if ("ResizeObserver" in window) new ResizeObserver(layout).observe(root);

    // ---- a frozen moment, for the README banner and the social card
    if (still) {
      (still.before || []).forEach(function (b) {
        var it = { id: ++uid, s: b[1], seed: false, from: b[0], ago: b[2] || 0 };
        DEVS.forEach(function (d) { lists[d].unshift(it); });
      });
      DEVS.forEach(function (d) { renderList(d); });
      var src = S.samples[still.s], it = { id: ++uid, s: still.s, seed: false, from: still.from, ago: 0 };
      lists[still.from].unshift(it);
      renderList(still.from);
      DEVS.filter(function (d) { return d !== still.from; }).forEach(function (d) {
        if ((still.arrived || []).indexOf(d) >= 0) { arrive(d, still.from, it, src); return; }
        var a = center(still.from), b = center(d), c = curve(a, b, 0.2), q = qpt(a, c, b, still.t);
        beam(a, c, b, "still");
        var f = flyer(src);
        f.style.transform = "translate(" + (q.x - f.offsetWidth / 2).toFixed(1) + "px," + (q.y - f.offsetHeight / 2).toFixed(1) + "px)";
        if (src.kind === "image") {
          showToast(d, still.from, fmt(S.receiving, S.names[still.from]), (still.progress * src.size).toFixed(1) + " / " + src.size.toFixed(1) + " MB", true);
          tiles[d].toast.querySelector(".bar2 i").style.width = (still.progress * 100) + "%";
        }
      });
    }

    return {
      setStrings: function (s) { S = s; applyStrings(); },
    };
  }

  window.NearclipDemo = { mount: mount };
})();

