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

  // ------------------------------------------------------------------ a sign-in check page, in a Windows or a Mac browser
  function verifyCard(page, T, mac) {
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
    el("span", { text: T.button }, btn);
    const ok = el("div.wb-ok", {}, card);
    if (mac) sym("checkmark.circle.fill", 18, "currentColor", ok); else icon("f", "checkmark_circle_filled", 20, ok);
    el("span", { text: T.done }, ok);
    return {
      card, btn, boxes,
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
    const vc = verifyCard(el("div.wb-page", {}, root), T, false);
    return { root, btn: vc.btn, boxes: vc.boxes, update: vc.update };
  };

  // Safari-like window with the same page.
  X.macBrowser = function (parent, { x, y, w = 940, h = 580, T }) {
    const root = el("div.mb", { style: { left: x + "px", top: y + "px", width: w + "px", height: h + "px" } }, parent);
    const tb = el("div.mb-tb", {}, root);
    const lights = el("div.mac-lights", {}, tb);
    for (const c of ["#ff5f57", "#febc2e", "#28c840"]) el("i", { style: { background: c } }, lights);
    const nav = el("div.mb-nav", {}, tb);
    sym("sidebar.left", 17, "currentColor", nav);
    sym("chevron.left", 14, "currentColor", nav);
    sym("chevron.right", 14, "currentColor", nav);
    const url = el("div.mb-url", {}, tb);
    sym("lock.fill", 11, "currentColor", url);
    el("span", { text: T.url }, url);
    const tools = el("div.mb-tools", {}, tb);
    sym("square.and.arrow.up", 16, "currentColor", tools);
    sym("plus", 15, "currentColor", tools);
    sym("rectangle.on.rectangle", 16, "currentColor", tools);
    const vc = verifyCard(el("div.mb-page", {}, root), T, true);
    return { root, btn: vc.btn, boxes: vc.boxes, update: vc.update };
  };

  // ------------------------------------------------------------------ Windows 11 app window
  X.winWindow = function (parent, { x, y, w, h, title, glyph }) {
    const root = el("div.ww", { style: { left: x + "px", top: y + "px", width: w + "px", height: h + "px" } }, parent);
    const tb = el("div.ww-tb", {}, root);
    const ic = el("span.ww-ic", {}, tb);
    if (glyph) glyph(ic);
    el("span.ww-title", { text: title }, tb);
    const ctl = el("div.ww-ctl", {}, tb);
    for (const s of ["subtract", "square", "dismiss"]) icon("f", s, 14, ctl);
    const body = el("div.ww-body", {}, root);
    return { root, body };
  };

  // A map app on the PC: paste an address into the search box, the place drops a pin. Flat shapes only.
  const PIN = '<svg viewBox="0 0 48 60"><path d="M24 2C12.4 2 3 11.2 3 22.6 3 38 24 58 24 58s21-20 21-35.4C45 11.2 35.6 2 24 2z" fill="#4C5BF5"/><circle cx="24" cy="22.5" r="8.5" fill="#fff"/></svg>';
  X.winMap = function (parent, { x, y, w = 1080, h = 600, T }) {
    const win = X.winWindow(parent, { x, y, w, h, title: T.title, glyph: (n) => icon("f", "location_filled", 16, n) });
    const bw = w, bh = h - 40;
    const map = el("div.map", {}, win.body);
    el("i.map-river", {}, map);
    el("i.map-park", { style: { left: bw * 0.72 + "px", top: bh * 0.08 + "px", width: bw * 0.18 + "px", height: bh * 0.24 + "px" } }, map);
    el("i.map-park", { style: { left: bw * 0.44 + "px", top: bh * 0.6 + "px", width: bw * 0.12 + "px", height: bh * 0.12 + "px" } }, map);
    const road = (x1, y1, x2, y2, main) => {
      const ax = x1 * bw, ay = y1 * bh, bx = x2 * bw, by = y2 * bh, hh = main ? 18 : 12;
      el("i.map-road" + (main ? ".main" : ""), { style: { left: ax + "px", top: ay - hh / 2 + "px", width: Math.hypot(bx - ax, by - ay) + "px",
        transform: "rotate(" + (Math.atan2(by - ay, bx - ax) * 180 / Math.PI).toFixed(2) + "deg)" } }, map);
    };
    road(0.3, 0.46, 1.05, 0.4, false);
    road(0.7, -0.05, 0.62, 1.05, false);
    road(0.47, -0.05, 0.56, 1.05, false);
    road(0.82, 0.55, 1.05, 0.66, false);
    road(0.3, 0.95, 1.05, 0.12, true);
    const P = [bw * 0.64, bh * 0.5];
    const pinWrap = el("div.map-pinwrap", { style: { left: P[0] + "px", top: P[1] + "px" } }, map);
    const shadow = el("i.map-shadow", {}, pinWrap);
    const ripple = el("i.map-ripple", {}, pinWrap);
    const pin = el("div.map-pin", {}, pinWrap, PIN);
    set(map, { transformOrigin: P[0] + "px " + P[1] + "px" });
    const panel = el("div.map-panel", {}, win.body);
    const search = el("div.map-search", {}, panel);
    icon("f", "search", 18, search);
    const q = el("span.map-q", { text: T.placeholder }, search);
    const caret = el("i.map-caret", {}, search);
    const res = el("div.map-res", {}, panel);
    const top = el("div.map-res-top", {}, res);
    icon("f", "location_filled", 18, el("span.map-res-ic", {}, top));
    const col = el("div.map-res-col", {}, top);
    el("b", { text: T.place }, col);
    el("span", { text: T.address }, col);
    const btns = el("div.map-res-btns", {}, res);
    const go = el("span.map-go", {}, btns);
    icon("f", "directions", 16, go);
    el("span", { text: T.directions }, go);
    const save = el("span.map-save", {}, btns);
    icon("f", "star", 16, save);
    el("span", { text: T.save }, save);
    return {
      root: win.root, search,
      update(t, { pasteAt, pinAt }) {
        const pasted = t >= pasteAt;
        txt(q, pasted ? T.address : T.placeholder);
        q.classList.toggle("typed", pasted);
        set(caret, { opacity: pasted || Math.floor(t * 1.8) % 2 === 0 ? "1" : "0" });
        set(search, { boxShadow: "0 2px 10px rgba(20,25,40,0.12), inset 0 0 0 " + (2 * (pasted ? 1 - prog(t, pasteAt + 0.2, pasteAt + 0.8) : 1)).toFixed(2) + "px rgba(76,91,245,0.9)" });
        const on = t >= pinAt;
        const ps = on ? clamp(spring(t - pinAt, 0.4, 0.55), 0, 1.35) : 0;
        set(pin, { opacity: on ? Math.min(1, (t - pinAt) / 0.08).toFixed(3) : "0", transform: "translateY(" + ((1 - Math.min(1, ps)) * -70).toFixed(1) + "px) scaleY(" + (1 + 0.12 * (ps - 1)).toFixed(3) + ")" });
        set(shadow, { opacity: on ? (0.9 * Math.min(1, ps)).toFixed(3) : "0", transform: "scale(" + (0.4 + 0.6 * Math.min(1, ps)).toFixed(3) + ")" });
        const rp = on ? prog(t, pinAt + 0.12, pinAt + 0.85) : 0;
        set(ripple, { opacity: (rp > 0 ? (1 - rp) * 0.9 : 0).toFixed(3), transform: "scale(" + (0.4 + 1.6 * E.outCubic(rp)).toFixed(3) + ")" });
        const rs = t >= pinAt + 0.1 ? clamp(spring(t - pinAt - 0.1, 0.45, 0.8), 0, 1.1) : 0;
        set(res, { opacity: prog(t, pinAt + 0.1, pinAt + 0.22).toFixed(3), transform: "translateY(" + ((1 - Math.min(1, rs)) * -12).toFixed(1) + "px)" });
        set(map, { transform: "scale(" + (1 + 0.05 * E.inOutCubic(prog(t, pinAt, pinAt + 1.2))).toFixed(4) + ")" });
      },
    };
  };

  // A chat on the PC: someone asks for a photo, Ctrl+V sends it, they answer.
  X.winChat = function (parent, { x, y, w = 760, h = 600, T, photo }) {
    const win = X.winWindow(parent, { x, y, w, h, title: T.title, glyph: (n) => icon("f", "chat_filled", 16, n) });
    const body = win.body;
    const head = el("div.wc-head", {}, body);
    const avs = el("div.wc-avs", {}, head);
    el("span", { text: T.a1, style: { background: "#f0a13a" } }, avs);
    el("span", { text: T.a2, style: { background: "#2fae6a" } }, avs);
    const hc = el("div.wc-hcol", {}, head);
    el("b", { text: T.room }, hc);
    el("span", { text: T.members }, hc);
    icon("f", "people", 20, el("span.wc-people", {}, head));
    const list = el("div.wc-list", {}, body);
    el("div.wc-day", { text: T.day }, list);
    const msg = (text, who, color, init) => {
      const row = el("div.wc-row", {}, list);
      el("div.wc-av", { text: init, style: { background: color } }, row);
      const col = el("div.wc-col", {}, row);
      if (who) el("div.wc-who", { text: who }, col);
      const line = el("div.wc-line", {}, col);
      el("div.wc-bubble", { text }, line);
      el("span.wc-time", { text: T.time }, line);
      return row;
    };
    msg(T.ask, T.a1name, "#f0a13a", T.a1);
    const mine = el("div.wc-row.out", {}, list);
    const mcol = el("div.wc-line", {}, mine);
    el("span.wc-time", { text: T.time }, mcol);
    el("img", { src: photo }, el("div.wc-photo", {}, mcol));
    const reply = msg(T.reply, null, "#f0a13a", T.a1);
    const input = el("div.wc-input", {}, body);
    icon("f", "attach", 20, input);
    icon("f", "emoji", 20, input);
    const field = el("div.wc-field", {}, input);
    const caret = el("i.wc-caret", {}, field);
    el("span", { text: T.placeholder }, field);
    icon("f", "send_filled", 18, el("span.wc-send", {}, input));
    const show = (node, t, at) => {
      if (at == null || t < at) { set(node, { display: "none" }); return; }
      const s = clamp(spring(t - at, 0.42, 0.68), 0, 1.25);
      set(node, { display: "", opacity: Math.min(1, (t - at) / 0.1).toFixed(3), transform: "translateY(" + ((1 - Math.min(1, s)) * 18).toFixed(1) + "px) scale(" + (0.82 + 0.18 * s).toFixed(4) + ")" });
    };
    return {
      root: win.root,
      update(t, { pasteAt, replyAt }) {
        show(mine, t, pasteAt);
        show(reply, t, replyAt);
        set(caret, { opacity: Math.floor(t * 1.8) % 2 === 0 ? "1" : "0" });
      },
    };
  };

  // ------------------------------------------------------------------ Android: the lock screen, a text message arriving
  // The phone lies on the desk with its screen off (always-on clock). The message wakes it and lands in the
  // notification list; Nearclip reads the notification, so the code is found without anyone touching the phone.
  X.androidLock = function (parent, { T }) {
    const root = el("div.al", {}, parent);
    const wall = el("div.al-wall", {}, root);
    const clock = el("div.al-clock", { text: T.lockTime }, root);
    const date = el("div.al-date", { text: T.lockDate }, root);
    const card = el("div.al-card", {}, root);
    const av = el("div.al-av", { text: T.initial }, card);
    icon("f", "chat_filled", 11, el("i.al-badge", {}, av));
    const col = el("div.al-col", {}, card);
    const head = el("div.al-head", {}, col);
    el("b", { text: T.sender }, head);
    el("span", { text: " · " + T.now }, head);
    const body = el("div.al-body", {}, col);
    el("span", { text: T.msgPre }, body);
    const code = el("span.al-code", {}, body);
    const hl = el("i.al-hl", {}, code);
    el("span", { text: T.code }, code);
    el("span", { text: T.msgPost }, body);
    const lock = el("div.al-lock", {}, root);
    icon("m", "lock", 22, lock);
    return {
      root, code,
      update(t, { wakeAt, arriveAt, detectAt }) {
        const wake = E.outCubic(prog(t, wakeAt, wakeAt + 0.3));
        set(wall, { opacity: wake.toFixed(3) });
        set(clock, { opacity: (0.55 + 0.45 * wake).toFixed(3) });
        set(date, { opacity: (0.45 + 0.55 * wake).toFixed(3) });
        set(lock, { opacity: wake.toFixed(3) });
        const s = t < arriveAt ? 0 : spring(t - arriveAt, 0.45, 0.8);
        set(card, { opacity: Math.min(1, prog(t, arriveAt, arriveAt + 0.14)).toFixed(3),
          transform: "translateY(" + ((1 - s) * -26).toFixed(2) + "px) scale(" + (0.95 + 0.05 * Math.min(1.02, s)).toFixed(4) + ")" });
        const d = E.outCubic(prog(t, detectAt, detectAt + 0.28));
        const bump = NC.win(t, detectAt + 0.1, detectAt + 0.5, 0.12, 0.28);
        set(hl, { width: "calc(" + (d * 100).toFixed(2) + "% + " + (d * 6).toFixed(2) + "px)", opacity: t < detectAt ? "0" : "0.45" });
        set(code, { transform: "scale(" + (1 + 0.05 * bump).toFixed(4) + ")" });
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

