// The apps around Nearclip in each demo (a note on the Mac, a sign-in page on Windows, a text message on Android)
// and the overlays: keycaps, pointers, touches and the clip card that travels between devices.
(function () {
  const { el, set, txt, sym, icon, clamp, prog, spring, E, lerp } = NC;
  const X = (NC.X = {});

  // ------------------------------------------------------------------ macOS note window
  X.macNote = function (parent, { x, y, w = 800, h = 520, date, title, lines = [], selectLine = -1 }) {
    const root = el("div.mac-win", { style: { left: x + "px", top: y + "px", width: w + "px", height: h + "px" } }, parent);
    const tb = el("div.mac-win-tb", {}, root);
    const lights = el("div.mac-lights", {}, tb);
    for (const c of ["#ff5f57", "#febc2e", "#28c840"]) el("i", { style: { background: c } }, lights);
    const tools = el("div.mac-win-tools", {}, tb);
    for (const s of ["list.bullet", "textformat", "checklist", "paperclip", "square.and.pencil"]) sym(s, 17, "currentColor", tools);
    const body = el("div.mac-note", {}, root);
    el("div.mac-note-date", { text: date }, body);
    el("div.mac-note-title", { text: title }, body);
    const refs = {};
    lines.forEach((ln, i) => {
      const p = el("div.mac-note-line", {}, body);
      if (ln.label) el("span.lbl", { text: ln.label }, p);
      if (ln.img) {
        const fig = el("div.mac-note-fig", {}, p);
        const im = el("img", { src: ln.img }, fig);
        refs.fig = fig; refs.figImg = im;
        return;
      }
      const v = el("span.val", {}, p);
      const hl = el("i.mac-sel", {}, v);
      el("span", { text: ln.text }, v);
      if (i === selectLine) { refs.sel = v; refs.hl = hl; }
    });
    return { root, refs, body };
  };

  // ------------------------------------------------------------------ Windows browser: a sign-in check page
  X.winBrowser = function (parent, { x, y, w = 900, h = 560, T }) {
    const root = el("div.wb", { style: { left: x + "px", top: y + "px", width: w + "px", height: h + "px" } }, parent);
    const tabs = el("div.wb-tabs", {}, root);
    const tab = el("div.wb-tab", {}, tabs);
    icon("f", "shield_lock", 14, tab);
    el("span", { text: T.tab }, tab);
    icon("f", "dismiss", 12, tab);
    icon("f", "add_16", 14, el("span.wb-new", {}, tabs));
    const ctl = el("div.wb-ctl", {}, tabs);
    for (const s of ["subtract", "square", "dismiss"]) icon("f", s, 14, ctl);
    const nav = el("div.wb-nav", {}, root);
    for (const s of ["arrow_left", "arrow_right", "arrow_clockwise"]) icon("f", s, 16, nav);
    const url = el("div.wb-url", {}, nav);
    icon("f", "lock_closed_filled_16", 12, url);
    el("span", { text: T.url }, url);
    icon("f", "star", 16, nav);
    const page = el("div.wb-page", {}, root);
    const card = el("div.wb-card", {}, page);
    el("div.wb-logo", { text: "i" }, card);
    el("h1", { text: T.heading }, card);
    el("p", { text: T.body }, card);
    const boxes = el("div.wb-boxes", {}, card);
    const digits = [];
    for (let i = 0; i < 6; i++) {
      const b = el("div.wb-box", {}, boxes);
      digits.push({ box: b, d: el("span", {}, b) });
    }
    const caret = el("i.wb-caret", {}, digits[0].box);
    const btn = el("div.wb-btn", {}, card);
    const btnLabel = el("span", { text: T.button }, btn);
    const ok = el("div.wb-ok", {}, card);
    icon("f", "checkmark_circle_filled", 20, ok);
    el("span", { text: T.done }, ok);
    return {
      root,
      update(t, { code, pasteAt, okAt }) {
        digits.forEach((dg, i) => {
          const at = pasteAt + i * 0.035;
          const on = t >= at;
          txt(dg.d, on ? code[i] : "");
          const s = on ? spring(t - at, 0.3, 0.6) : 0;
          set(dg.d, { transform: "scale(" + (0.6 + 0.4 * s).toFixed(3) + ")", opacity: on ? Math.min(1, (t - at) / 0.06).toFixed(3) : "0" });
          dg.box.classList.toggle("filled", on);
          dg.box.classList.toggle("focus", (!on && i === 0 && t < pasteAt) || false);
        });
        set(caret, { opacity: t < pasteAt && Math.floor(t * 1.8) % 2 === 0 ? "1" : "0" });
        const done = okAt != null && t >= okAt;
        btn.classList.toggle("done", done);
        set(btn, { transform: "scale(" + (okAt != null ? 1 - 0.04 * NC.win(t, okAt - 0.18, okAt - 0.05, 0.05, 0.12) : 1).toFixed(3) + ")" });
        set(ok, { opacity: done ? prog(t, okAt, okAt + 0.25).toFixed(3) : "0", transform: "translateY(" + (done ? (1 - E.outCubic(prog(t, okAt, okAt + 0.35))) * 8 : 8).toFixed(1) + "px)" });
      },
    };
  };

  // ------------------------------------------------------------------ Android: a text message, selection, toolbar
  X.androidMessages = function (parent, { T, dark = true }) {
    const root = el("div.am" + (dark ? ".dark" : ""), {}, parent);
    const bar = el("div.am-bar", {}, root);
    icon("m", "arrow_back", 24, bar);
    el("div.am-av", { text: T.initial }, bar);
    el("span.am-name", { text: T.sender }, bar);
    el("div.spacer", {}, bar);
    icon("m", "more_vert", 24, bar);
    const thread = el("div.am-thread", {}, root);
    el("div.am-day", { text: T.day }, thread);
    const bubble = el("div.am-bubble", {}, thread);
    const pre = el("span", { text: T.msgPre }, bubble);
    const code = el("span.am-code", {}, bubble);
    const hl = el("i.am-hl", {}, code);
    el("span", { text: T.code }, code);
    const hL = el("i.am-handle.l", {}, code);
    const hR = el("i.am-handle.r", {}, code);
    el("span", { text: T.msgPost }, bubble);
    el("div.am-time", { text: T.time }, thread);
    const input = el("div.am-input", {}, root);
    icon("m", "add", 24, el("span.am-plus", {}, input));
    el("div.am-field", { text: T.field }, input);
    const tb = el("div.am-tb", {}, root);
    const items = T.toolbar.map((s, i) => el("span" + (i === T.toolbar.length - 1 ? ".send" : ""), { text: s }, tb));
    return {
      root, code, toolbar: tb, sendItem: items[items.length - 1],
      update(t, { selectAt, tapAt }) {
        const sel = selectAt != null && t >= selectAt && (tapAt == null || t < tapAt + 0.35);
        const s = sel ? E.outCubic(prog(t, selectAt, selectAt + 0.18)) : 0;
        set(hl, { opacity: sel ? (0.42 * s).toFixed(3) : "0" });
        set(hL, { opacity: sel ? s.toFixed(3) : "0" });
        set(hR, { opacity: sel ? s.toFixed(3) : "0" });
        const tbOn = selectAt != null ? NC.win(t, selectAt + 0.12, tapAt + 0.12, 0.22, 0.16) : 0;
        set(tb, { opacity: tbOn.toFixed(3), transform: "translate(-50%," + ((1 - tbOn) * 8).toFixed(1) + "px) scale(" + (0.92 + 0.08 * tbOn).toFixed(3) + ")" });
        const press = tapAt != null ? NC.win(t, tapAt - 0.08, tapAt + 0.05, 0.06, 0.15) : 0;
        set(items[items.length - 1], { background: "rgba(188,195,255," + (0.12 + 0.2 * press).toFixed(3) + ")" });
      },
    };
  };

  // ------------------------------------------------------------------ overlays
  // A keycap. label: main glyph, sub: small word under it (Mac modifier keys).
  X.keycap = function (parent, { label, sub, w = 96 }) {
    const root = el("div.key", { style: { width: w + "px" } }, parent);
    const face = el("div.key-face", {}, root);
    el("b", { text: label }, face);
    if (sub) el("small", { text: sub }, face);
    return {
      root,
      update(t, { show, hide, down, up, x, y, s = 1 }) {
        const on = NC.win(t, show, hide, 0.25, 0.22, E.outBack);
        if (on <= 0) { set(root, { display: "none" }); return; }
        const p = down != null && t >= down && t < up + 0.12 ? (t < up ? E.outCubic(prog(t, down, down + 0.05)) : 1 - E.outCubic(prog(t, up, up + 0.12))) : 0;
        set(root, { display: "", opacity: Math.min(1, on * 1.4).toFixed(3), transform: "translate(" + x + "px," + (y + (1 - on) * 26).toFixed(1) + "px) scale(" + (s * (0.86 + 0.14 * on)).toFixed(3) + ")" });
        set(face, { transform: "translateY(" + (p * 6).toFixed(2) + "px)", "--depth": (7 - 6 * p).toFixed(2) + "px" });
      },
    };
  };

  // macOS arrow pointer / I-beam.
  X.pointer = function (parent) {
    const root = el("div.ptr", {}, parent,
      '<svg class="arrow" viewBox="0 0 28 28"><path d="M8 3.5 L8 21.5 L12.3 17.6 L15.2 24.2 L18.2 22.9 L15.4 16.5 L21.2 16.5 Z" fill="#000" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>' +
      '<svg class="beam" viewBox="0 0 28 28"><path d="M10 4.5 Q14 4.5 14 7 Q14 4.5 18 4.5 M14 7 L14 21 M10 23.5 Q14 23.5 14 21 Q14 23.5 18 23.5" fill="none" stroke="#fff" stroke-width="4" stroke-linecap="round"/><path d="M10 4.5 Q14 4.5 14 7 Q14 4.5 18 4.5 M14 7 L14 21 M10 23.5 Q14 23.5 14 21 Q14 23.5 18 23.5" fill="none" stroke="#111" stroke-width="1.7" stroke-linecap="round"/></svg>');
    return {
      root,
      update(t, { x, y, show = true, beam = false, s = 1 }) {
        set(root, { display: show ? "" : "none", transform: "translate(" + x.toFixed(1) + "px," + y.toFixed(1) + "px) scale(" + s + ")" });
        root.classList.toggle("is-beam", beam);
      },
    };
  };

  // A touch on a phone screen: a soft dot that presses and ripples.
  X.touch = function (parent, { dark = false } = {}) {
    const root = el("div.touch" + (dark ? ".dark" : ""), {}, parent);
    const ring = el("i.touch-ring", {}, root);
    return {
      root,
      update(t, { x, y, down, up, show, hide, long = false }) {
        const on = NC.win(t, show, hide, 0.15, 0.2);
        if (on <= 0) { set(root, { display: "none" }); return; }
        const pressed = t >= down && t < up;
        const pr = pressed ? E.outCubic(prog(t, down, down + 0.08)) : t >= up ? 1 - E.outCubic(prog(t, up, up + 0.15)) : 0;
        set(root, { display: "", opacity: on.toFixed(3), transform: "translate(" + x.toFixed(1) + "px," + y.toFixed(1) + "px) scale(" + (1 - 0.18 * pr).toFixed(3) + ")" });
        const rp = t >= down ? prog(t, down, down + (long ? 0.55 : 0.4)) : 0;
        set(ring, { opacity: (t >= down ? (1 - rp) * 0.9 : 0).toFixed(3), transform: "scale(" + (1 + rp * (long ? 1.6 : 1.1)).toFixed(3) + ")" });
      },
    };
  };

  // The clip on its way: a small card that lifts off one device and lands in the other's list.
  X.chip = function (parent, { kind = "text" } = {}) {
    const root = el("div.chip", {}, parent);
    const card = el("div.chip-card", {}, root);
    el("div.chip-brand", {}, card, NC_ICONS.brand.tile);
    const label = el("span.chip-text", {}, card);
    const img = el("img.chip-img", {}, card);
    return {
      root,
      update(t, { start, end, from, to, text, image, scale = 1, arc = -160, toScale = 0.6 }) {
        if (t < start - 0.25 || t > end + 0.05) { set(root, { display: "none" }); return; }
        const lift = E.outCubic(prog(t, start - 0.25, start));
        const u = E.inOutCubic(prog(t, start, end));
        const mid = [(from[0] + to[0]) / 2, Math.min(from[1], to[1]) + arc];
        let [x, y] = NC.bez(from, mid, to, u);
        if (t < start) y -= 18 * lift;
        else y -= 18 * (1 - u);
        const sc = scale * lerp(1 + 0.06 * lift, toScale, E.inCubic(prog(t, end - 0.28, end)));
        const fade = 1 - prog(t, end - 0.06, end + 0.04);
        const rot = Math.sin(u * Math.PI) * (to[0] > from[0] ? 4 : -4);
        txt(label, text || "");
        set(label, { display: image ? "none" : "" });
        if (image) { if (img.getAttribute("src") !== image) img.setAttribute("src", image); set(img, { display: "" }); } else set(img, { display: "none" });
        set(root, { display: "", opacity: (Math.min(1, lift * 1.3) * fade).toFixed(3), transform: "translate(" + x.toFixed(1) + "px," + y.toFixed(1) + "px) rotate(" + rot.toFixed(2) + "deg) scale(" + sc.toFixed(3) + ")" });
      },
    };
  };
})();

