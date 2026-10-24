// Helpers for the deterministic promo stage: every frame is a pure function of time (renderAt(t)).
(function () {
  const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
  const lerp = (a, b, t) => a + (b - a) * t;
  const prog = (t, a, b) => clamp((t - a) / (b - a));
  const E = {
    linear: (x) => x,
    inQuad: (x) => x * x,
    outQuad: (x) => 1 - (1 - x) * (1 - x),
    inCubic: (x) => x * x * x,
    outCubic: (x) => 1 - Math.pow(1 - x, 3),
    inOutCubic: (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2),
    outQuart: (x) => 1 - Math.pow(1 - x, 4),
    inQuart: (x) => x * x * x * x,
    inOutQuart: (x) => (x < 0.5 ? 8 * x * x * x * x : 1 - Math.pow(-2 * x + 2, 4) / 2),
    outQuint: (x) => 1 - Math.pow(1 - x, 5),
    inOutQuint: (x) => (x < 0.5 ? 16 * x * x * x * x * x : 1 - Math.pow(-2 * x + 2, 5) / 2),
    inExpo: (x) => (x === 0 ? 0 : Math.pow(2, 10 * x - 10)),
    outExpo: (x) => (x === 1 ? 1 : 1 - Math.pow(2, -10 * x)),
    inOutExpo: (x) => (x === 0 ? 0 : x === 1 ? 1 : x < 0.5 ? Math.pow(2, 20 * x - 10) / 2 : (2 - Math.pow(2, -20 * x + 10)) / 2),
    outBack: (x) => { const c1 = 1.25, c3 = c1 + 1; return 1 + c3 * Math.pow(x - 1, 3) + c1 * Math.pow(x - 1, 2); },
    inOutSine: (x) => -(Math.cos(Math.PI * x) - 1) / 2,
  };

  // SwiftUI-style spring(response, dampingFraction) from 0 to 1; t in seconds since the start.
  function spring(t, response = 0.35, damping = 0.82) {
    if (t <= 0) return 0;
    const w0 = (2 * Math.PI) / response;
    const z = damping;
    if (z < 1) {
      const wd = w0 * Math.sqrt(1 - z * z);
      return 1 - Math.exp(-z * w0 * t) * (Math.cos(wd * t) + ((z * w0) / wd) * Math.sin(wd * t));
    }
    return 1 - Math.exp(-w0 * t) * (1 + w0 * t);
  }

  // Keyframes [[t, value, ease?], ...]; the ease applies to the segment ending at that key. Values may be arrays.
  function kf(t, keys) {
    if (t <= keys[0][0]) return keys[0][1];
    for (let i = 1; i < keys.length; i++) {
      const [t1, v1, ease] = keys[i];
      const [t0, v0] = keys[i - 1];
      if (t <= t1) {
        const p = t1 === t0 ? 1 : (t - t0) / (t1 - t0);
        const e = (ease || E.inOutCubic)(p);
        if (Array.isArray(v0)) return v0.map((a, j) => lerp(a, v1[j], e));
        return lerp(v0, v1, e);
      }
    }
    return keys[keys.length - 1][1];
  }

  // 0 → 1 on enter, 1 → 0 on leave.
  function win(t, start, end, inDur = 0.3, outDur = 0.3, inEase = E.outCubic, outEase = E.inCubic) {
    if (t < start || t > end + outDur) return 0;
    const a = inDur > 0 ? inEase(prog(t, start, start + inDur)) : 1;
    const b = end === Infinity ? 1 : outDur > 0 ? 1 - outEase(prog(t, end, end + outDur)) : t > end ? 0 : 1;
    return Math.min(a, b);
  }

  const NS = "http://www.w3.org/2000/svg";
  const SVG_TAGS = new Set(["svg", "path", "g", "circle", "rect", "defs", "clipPath", "mask", "line", "polyline", "ellipse", "text"]);
  // el("div.class1.class2", {attrs}, parent, html)
  function el(spec, attrs = {}, parent, html) {
    const [tag, ...classes] = spec.split(".");
    const node = SVG_TAGS.has(tag) ? document.createElementNS(NS, tag) : document.createElement(tag || "div");
    if (classes.length) node.setAttribute("class", classes.join(" "));
    for (const [k, v] of Object.entries(attrs || {})) {
      if (k === "style" && typeof v === "object") Object.assign(node.style, v);
      else if (k === "text") node.textContent = v;
      else node.setAttribute(k, v);
    }
    if (html !== undefined) node.innerHTML = html;
    if (parent) parent.appendChild(node);
    return node;
  }

  // Style writes are cached per node so an unchanged frame touches nothing.
  function set(node, styles) {
    if (!node) return;
    const cache = node.__s || (node.__s = {});
    for (const k in styles) {
      const v = styles[k];
      if (cache[k] === v) continue;
      cache[k] = v;
      if (k.startsWith("--")) node.style.setProperty(k, v);
      else node.style[k] = v;
    }
  }
  function txt(node, value) {
    if (node.__t === value) return;
    node.__t = value;
    node.textContent = value;
  }
  function attr(node, name, value) {
    const key = "__a_" + name;
    if (node[key] === value) return;
    node[key] = value;
    node.setAttribute(name, value);
  }

  // SF Symbol (exported mask) tinted with color.
  function sym(name, size, color, parent, cls = "") {
    const node = el("i.sym" + (cls ? "." + cls : ""), {}, parent);
    Object.assign(node.style, {
      width: size + "px", height: size + "px", background: color || "currentColor",
      webkitMaskImage: "url(assets/symbols/" + name + ".png)", maskImage: "url(assets/symbols/" + name + ".png)",
    });
    return node;
  }
  // Material (m) / Fluent (f) / brand SVG icon.
  function icon(set_, name, size, parent, cls = "") {
    const src = (window.NC_ICONS[set_] || {})[name];
    if (!src) console.error("missing icon", set_, name);
    const node = el("i.ico" + (cls ? "." + cls : ""), { style: { width: size + "px", height: size + "px" } }, parent, src || "");
    return node;
  }

  function hex(c) {
    if (c.startsWith("rgb")) return c.slice(c.indexOf("(") + 1, -1).split(",").map(Number);
    const n = parseInt(c.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  const mix = (a, b, t) => {
    const pa = hex(a), pb = hex(b);
    return "rgb(" + pa.map((c, i) => Math.round(lerp(c, pb[i], t))).join(",") + ")";
  };

  // Deterministic pseudo-random in [0, 1) for a seed.
  const rnd = (seed) => { const x = Math.sin(seed * 12.9898 + 78.233) * 43758.5453; return x - Math.floor(x); };

  // Quadratic Bézier point and the screen rect of a node (after the frame's transforms are applied).
  const bez = (p0, p1, p2, u) => [lerp(lerp(p0[0], p1[0], u), lerp(p1[0], p2[0], u), u), lerp(lerp(p0[1], p1[1], u), lerp(p1[1], p2[1], u), u)];
  function rect(node) {
    const r = node.getBoundingClientRect();
    return { x: r.left, y: r.top, w: r.width, h: r.height, cx: r.left + r.width / 2, cy: r.top + r.height / 2 };
  }

  globalThis.NC = { clamp, lerp, prog, E, spring, kf, win, el, set, txt, attr, sym, icon, hex, mix, rnd, bez, rect };
})();

