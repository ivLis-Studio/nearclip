// Nearclip's own UI on each platform, rebuilt from the apps (apple/macOS/HistoryView.swift, apple/iOS/HomeView.swift,
// android/.../ui/home, windows/.../Views/FlyoutWindow.xaml) and their screenshots in docs/screenshots.
// Every history list shares one engine: rows are absolutely placed, a clip that arrives at time "at" grows in at the
// top with a spring and pushes the others down, so the whole list is a pure function of t.
(function () {
  const { el, set, txt, sym, icon, clamp, prog, spring, E, lerp } = NC;
  const A = (NC.A = {});

  // ------------------------------------------------------------------ list engine
  // items: [{ id, at (arrival time or null), ... }]; heights: id → px. Returns id → { y, g, on, flash }.
  A.layout = function (items, t, heightOf, gap = 0) {
    const arrived = items.filter((it) => it.at != null && t >= it.at).sort((a, b) => b.at - a.at);
    const base = items.filter((it) => it.at == null);
    const order = [...arrived, ...base];
    const out = {};
    let y = 0;
    for (const it of order) {
      let g = it.at == null ? 1 : clamp(spring(t - it.at, 0.55, 0.88), 0, 1.03);
      let a = it.at == null ? 1 : prog(t, it.at + 0.06, it.at + 0.32);
      // it.out: filtered away (search) from that time on, it.back: shown again
      if (it.out != null && t >= it.out) {
        const gone = it.back != null && t >= it.back ? 1 - clamp(spring(t - it.back, 0.5, 0.9)) : clamp(spring(t - it.out, 0.42, 0.95));
        g *= 1 - gone;
        a *= 1 - Math.min(1, gone * 1.6);
      }
      out[it.id] = { y, g, on: g > 0.002, a, flash: it.at == null ? 0 : Math.max(0, 1 - Math.max(0, t - it.at - 0.6) / 1.6) * prog(t, it.at, it.at + 0.2) };
      y += (heightOf(it) + gap) * g;
    }
    for (const it of items) if (!out[it.id]) out[it.id] = { y: 0, g: 0, on: false, a: 0, flash: 0 };
    out.__total = y;
    return out;
  };

  const devSym = { mac: "laptopcomputer", iphone: "iphone", android: "iphone", win: "pc" };
  const devMat = { mac: "laptop_mac", iphone: "phone_iphone", android: "smartphone", win: "desktop_windows" };
  const devFlu = { mac: "laptop_16", iphone: "phone_16", android: "phone_16", win: "desktop_16" };

  function placeRows(rows, lay, t, opt = {}) {
    for (const r of rows) {
      const l = lay[r.item.id];
      if (!l.on) { set(r.el, { display: "none" }); continue; }
      const grow = r.item.at == null && r.item.out == null ? 1 : l.g;
      set(r.el, {
        display: "", transform: "translate(0px," + (l.y + (opt.drop || -10) * (1 - Math.min(1, grow))).toFixed(2) + "px) scale(" + (0.97 + 0.03 * Math.min(1, grow)).toFixed(4) + ")",
        opacity: l.a.toFixed(3),
      });
      if (r.flash) set(r.flash, { opacity: (l.flash * (opt.flash || 1)).toFixed(3) });
    }
  }

  // Leading tile per clip kind, in each platform's idiom.
  function lead(parent, item, P) {
    const tile = el("div." + P + "-tile" + (item.kind === "link" ? ".link" : ""), {}, parent);
    if (item.kind === "image") {
      el("img", { src: item.img }, tile);
      tile.classList.add("img");
    } else if (item.kind === "color") {
      tile.classList.add("swatch");
      el("i", { style: { background: item.color } }, tile);
    } else if (P === "mac" || P === "ios") sym(item.kind === "link" ? "link" : "text.alignleft", P === "ios" ? 17 : 14, "currentColor", tile);
    else if (P === "win") icon("f", item.kind === "link" ? "link" : "text_align_left", 16, tile);
    else icon("m", item.kind === "link" ? "link" : "notes", 22, tile);
    return tile;
  }
  function titleOf(parent, item, P) {
    const t = el("div." + P + "-title", {}, parent);
    if (item.kind === "link") { el("b", { text: item.host }, t); el("span.dim", { text: item.path || "" }, t); }
    else if (item.kind === "image") { el("span", { text: item.title }, t); el("span.dim", { text: item.meta ? " · " + item.meta : "" }, t); }
    else if (item.kind === "color") { el("span.mono", { text: item.color.toUpperCase() }, t); }
    else el("span", { text: item.title }, t);
    return t;
  }
  function subOf(parent, item, P) {
    const s = el("div." + (P === "android" ? "and" : P) + "-sub", {}, parent);
    if (P === "mac" || P === "ios") sym(devSym[item.dev], P === "ios" ? 11 : 10, "currentColor", s);
    else if (P === "win") icon("f", devFlu[item.dev], 12, s);
    else icon("m", devMat[item.dev], 14, s);
    el("span", { text: item.src + " · " + item.ago }, s);
    if (item.pinned) {
      if (P === "android") icon("m", "push_pin_filled", 16, el("span.pin", {}, s));
      else if (P === "win") icon("f", "pin_filled_16", 12, el("span.pin", {}, s));
      else sym("pin.fill", 9, "var(--iris)", s);
    }
    return s;
  }

  // ------------------------------------------------------------------ macOS: the menu bar panel (380×540)
  A.macPanel = function (parent, { dark = false, items = [], T, status, devices = [] } = {}) {
    const root = el("div.mac-panel" + (dark ? ".dark" : ""), {}, parent);
    const head = el("div.mac-head", {}, root);
    el("div.mac-brand", {}, head, NC_ICONS.brand.tile);
    el("b", { text: "Nearclip" }, head);
    el("div.spacer", {}, head);
    const stack = el("div.mac-stack", {}, head);
    for (const d of devices) {
      const a = el("span.mac-av" + (d.on ? ".on" : ""), {}, stack);
      sym(devSym[d.dev], 11, "currentColor", a);
      if (d.on) el("i.dot", {}, a);
    }
    sym("ellipsis.circle", 16, "currentColor", head, "dimc");
    const search = el("div.mac-search", {}, root);
    sym("magnifyingglass", 12, "currentColor", search, "dimc");
    const q = el("span.mac-q", { text: T.search }, search);
    const caret = el("i.mac-caret", {}, search);
    const filters = el("div.mac-filters", {}, root);
    T.filters.forEach((f, i) => el("span" + (i === 0 ? ".on" : ""), { text: f }, filters));
    el("div.mac-div", { style: { top: "114px" } }, root);
    const list = el("div.mac-list", {}, root);
    el("div.mac-sec", { text: T.today }, list);
    const rowsBox = el("div.mac-rows", {}, list);
    const rows = items.map((item, i) => {
      const r = el("div.mac-row", {}, rowsBox);
      const flash = el("div.mac-flash", {}, r);
      lead(r, item, "mac");
      const mid = el("div.mac-mid", {}, r);
      titleOf(mid, item, "mac");
      subOf(mid, item, "mac");
      const key = el("span.mac-key", { text: "" }, r);
      return { el: r, flash, key, item };
    });
    el("div.mac-div", { style: { top: "502px" } }, root);
    const foot = el("div.mac-foot", {}, root);
    el("i.dot", {}, foot);
    el("span", { text: status }, foot);
    el("div.spacer", {}, foot);
    sym("plus", 12, "currentColor", foot);
    sym("pause.fill", 11, "currentColor", foot);
    return {
      root, rows, q, caret, box: rowsBox, search,
      update(t, { select, query, focus = false } = {}) {
        const lay = A.layout(items, t, () => 50);
        placeRows(rows, lay, t);
        const order = rows.filter((r) => lay[r.item.id].on).sort((a, b) => lay[a.item.id].y - lay[b.item.id].y);
        order.forEach((r, i) => txt(r.key, i < 9 ? "⌘" + (i + 1) : ""));
        for (const r of rows) r.el.classList.toggle("sel", select === r.item.id);
        if (query != null) { txt(q, query || T.search); q.classList.toggle("typed", !!query); }
        set(caret, { opacity: focus && Math.floor(t * 1.8) % 2 === 0 ? "1" : "0" });
      },
      row(id) { return rows.find((r) => r.item.id === id); },
    };
  };

  // macOS toast (ToastController): top-right under the menu bar.
  A.macToast = function (parent, { dark = true } = {}) {
    const root = el("div.mac-toast" + (dark ? ".dark" : ""), {}, parent);
    const ic = el("div.mac-toast-ic", {}, root);
    const icSym = sym("iphone", 14, "#fff", ic);
    const col = el("div.mac-toast-col", {}, root);
    const title = el("b", {}, col);
    const sub = el("span", {}, col);
    const thumb = el("img.mac-toast-thumb", {}, root);
    return {
      root,
      update(t, { start, end = start + 2.6, from, preview, img, dev = "iphone" }) {
        const on = NC.win(t, start, end, 0.01, 0.3);
        if (on <= 0) { set(root, { display: "none" }); return; }
        const s = spring(t - start, 0.42, 0.78);
        txt(title, from); txt(sub, preview);
        set(icSym, { webkitMaskImage: "url(assets/symbols/" + devSym[dev] + ".png)", maskImage: "url(assets/symbols/" + devSym[dev] + ".png)" });
        if (img) { if (thumb.getAttribute("src") !== img) thumb.setAttribute("src", img); set(thumb, { display: "" }); } else set(thumb, { display: "none" });
        const out = t > end ? E.inCubic(prog(t, end, end + 0.3)) : 0;
        set(root, { display: "", opacity: (Math.min(1, prog(t, start, start + 0.12)) * (1 - out)).toFixed(3), transform: "translateX(" + ((1 - s) * 60 + out * 30).toFixed(1) + "px)" });
      },
    };
  };

  // ------------------------------------------------------------------ Windows: the tray flyout (360×520)
  A.winFlyout = function (parent, { dark = false, items = [], T, status, devices = [] } = {}) {
    const root = el("div.win-fly" + (dark ? ".dark" : ""), {}, parent);
    const head = el("div.win-head", {}, root);
    el("div.win-brand", {}, head, NC_ICONS.brand.tile);
    el("b", { text: "Nearclip" }, head);
    el("div.spacer", {}, head);
    const stack = el("div.win-stack", {}, head);
    for (const d of devices) {
      const a = el("span.win-av" + (d.on ? ".on" : ""), {}, stack);
      icon("f", devFlu[d.dev], 13, a);
      if (d.on) el("i.dot", {}, a);
    }
    icon("f", "more_horizontal", 16, el("span.win-more", {}, head));
    const search = el("div.win-search", {}, root);
    el("span", { text: T.search }, search);
    icon("f", "search", 15, search);
    const tabs = el("div.win-tabs", {}, root);
    T.filters.forEach((f, i) => el("span" + (i === 0 ? ".on" : ""), { text: f }, tabs));
    el("div.win-div", { style: { top: "136px" } }, root);
    const list = el("div.win-list", {}, root);
    el("div.win-sec", { text: T.today }, list);
    const rowsBox = el("div.win-rows", {}, list);
    const rows = items.map((item) => {
      const r = el("div.win-row", {}, rowsBox);
      const flash = el("div.win-flash", {}, r);
      lead(r, item, "win");
      const mid = el("div.win-mid", {}, r);
      titleOf(mid, item, "win");
      subOf(mid, item, "win");
      const key = el("span.win-key", {}, r);
      return { el: r, flash, key, item };
    });
    el("div.win-div", { style: { top: "476px" } }, root);
    const foot = el("div.win-foot", {}, root);
    el("i.dot", {}, foot);
    el("span", { text: status }, foot);
    el("div.spacer", {}, foot);
    icon("f", "add", 15, foot);
    icon("f", "pause", 15, foot);
    return {
      root, rows, box: rowsBox,
      update(t, { select } = {}) {
        const lay = A.layout(items, t, () => 52);
        placeRows(rows, lay, t);
        const order = rows.filter((r) => lay[r.item.id].on).sort((a, b) => lay[a.item.id].y - lay[b.item.id].y);
        order.forEach((r, i) => txt(r.key, i < 9 ? "Ctrl+" + (i + 1) : ""));
        for (const r of rows) r.el.classList.toggle("sel", select === r.item.id);
      },
      row(id) { return rows.find((r) => r.item.id === id); },
    };
  };

  // Windows toast (ToastWindow.xaml): bottom-right above the taskbar.
  A.winToast = function (parent, { dark = false } = {}) {
    const root = el("div.win-toast" + (dark ? ".dark" : ""), {}, parent);
    const ic = el("div.win-toast-ic", {}, root);
    const icPhone = icon("f", "phone", 18, ic);
    const icLaptop = icon("f", "laptop", 18, ic);
    const col = el("div.win-toast-col", {}, root);
    const title = el("span.t", {}, col);
    const sub = el("span.s", {}, col);
    const thumb = el("img.win-toast-thumb", {}, root);
    return {
      root,
      update(t, { start, end = start + 2.6, from, preview, img, dev = "phone" }) {
        const on = NC.win(t, start, end, 0.01, 0.3);
        if (on <= 0) { set(root, { display: "none" }); return; }
        const s = spring(t - start, 0.45, 0.85);
        txt(title, from); txt(sub, preview);
        set(icPhone, { display: dev === "mac" ? "none" : "" });
        set(icLaptop, { display: dev === "mac" ? "" : "none" });
        if (img) { if (thumb.getAttribute("src") !== img) thumb.setAttribute("src", img); set(thumb, { display: "" }); } else set(thumb, { display: "none" });
        const out = t > end ? E.inCubic(prog(t, end, end + 0.3)) : 0;
        set(root, { display: "", opacity: (Math.min(1, prog(t, start, start + 0.15)) * (1 - out)).toFixed(3), transform: "translateY(" + ((1 - s) * 40 + out * 20).toFixed(1) + "px)" });
      },
    };
  };

  // ------------------------------------------------------------------ Android: HomeScreen (412×915 dp)
  A.androidHome = function (parent, { dark = false, items = [], T, connected = "", devices = [] } = {}) {
    const root = el("div.and-home" + (dark ? ".dark" : ""), {}, parent);
    const bar = el("div.and-bar", {}, root);
    el("div.and-brand", {}, bar, NC_ICONS.brand.tile);
    el("span.and-name", { text: "Nearclip" }, bar);
    el("div.spacer", {}, bar);
    const chip = el("div.and-devchip", {}, bar);
    for (const d of devices) icon("m", devMat[d.dev], 15, el("span.and-av", {}, chip));
    el("i.dot", {}, chip);
    el("span", { text: connected }, chip);
    icon("m", "settings", 24, el("span.and-gear", {}, bar));
    const search = el("div.and-search", {}, root);
    icon("m", "search", 24, search);
    el("span", { text: T.search }, search);
    const chips = el("div.and-chips", {}, root);
    T.filters.forEach((f, i) => { const c = el("span" + (i === 0 ? ".on" : ""), {}, chips); if (i === 0) icon("m", "check", 18, c); el("b", { text: f }, c); });
    const list = el("div.and-list", {}, root);
    el("div.and-sec", { text: T.today }, list);
    const rowsBox = el("div.and-rows", {}, list);
    const rows = items.map((item) => {
      const r = el("div.and-row", {}, rowsBox);
      const flash = el("div.and-flash", {}, r);
      lead(r, item, "and");
      const mid = el("div.and-mid", {}, r);
      titleOf(mid, item, "and");
      subOf(mid, item, "android");
      return { el: r, flash, item };
    });
    const fab = el("div.and-fab", {}, root);
    icon("m", "content_paste_go", 24, fab);
    el("span", { text: T.sendClipboard }, fab);
    return {
      root, rows, box: rowsBox, fab,
      update(t) {
        const lay = A.layout(items, t, (it) => (it.tall ? 104 : 82));
        placeRows(rows, lay, t, { drop: -14 });
      },
      row(id) { return rows.find((r) => r.item.id === id); },
    };
  };

  // Android toast (app icon + text) at the bottom of the screen.
  A.androidToast = function (parent, { dark = false } = {}) {
    const root = el("div.and-toast" + (dark ? ".dark" : ""), {}, parent);
    el("div.and-toast-ic", {}, root, NC_ICONS.brand.tile);
    const label = el("span", {}, root);
    return {
      root,
      update(t, { start, end = start + 2, text }) {
        const on = NC.win(t, start, end, 0.18, 0.25);
        if (on <= 0) { set(root, { display: "none" }); return; }
        txt(label, text);
        set(root, { display: "", opacity: on.toFixed(3), transform: "translateY(" + ((1 - on) * 14).toFixed(1) + "px) scale(" + (0.94 + 0.06 * on).toFixed(3) + ")" });
      },
    };
  };

  // ------------------------------------------------------------------ iOS: HomeView (402×874 pt)
  A.iosHome = function (parent, { items = [], T, status, statusSub, devices = [], chipsOffset = 0 } = {}) {
    const root = el("div.ios-home", {}, parent);
    const tools = el("div.ios-tools", {}, root);
    sym("plus", 20, "var(--iris)", tools);
    sym("gearshape", 20, "var(--iris)", tools);
    el("div.ios-large", { text: "Nearclip" }, root);
    const card = el("div.ios-card.ios-statuscard", {}, root);
    const radio = el("div.ios-radio", {}, card);
    sym("dot.radiowaves.left.and.right", 18, "var(--online)", radio);
    const st = el("div.ios-stcol", {}, card);
    el("b", { text: status }, st);
    el("span", { text: statusSub }, st);
    const av = el("div.ios-avs", {}, card);
    for (const d of devices) sym(devSym[d.dev], 11, "currentColor", el("span" + (d.on ? ".on" : ""), {}, av));
    sym("chevron.right", 12, "#c4c4c8", card);
    const chips = el("div.ios-chips", { style: { transform: "translateX(" + -chipsOffset + "px)" } }, root);
    const chipSyms = ["square.stack", "text.alignleft", "link", "photo", "pin"];
    T.filters.forEach((f, i) => { const c = el("span" + (i === 0 ? ".on" : ""), {}, chips); sym(chipSyms[i], 15, "currentColor", c); el("b", { text: f }, c); });
    el("div.ios-sec", { text: T.today }, root);
    const group = el("div.ios-group", {}, root);
    const rowsBox = el("div.ios-rows", {}, group);
    const rows = items.map((item) => {
      const r = el("div.ios-row", {}, rowsBox);
      const flash = el("div.ios-flash", {}, r);
      lead(r, item, "ios");
      const mid = el("div.ios-mid", {}, r);
      titleOf(mid, item, "ios");
      subOf(mid, item, "ios");
      el("i.ios-sep", {}, r);
      return { el: r, flash, item };
    });
    const searchBar = el("div.ios-searchbar", {}, root);
    sym("magnifyingglass", 17, "currentColor", searchBar);
    el("span", { text: T.search }, searchBar);
    // Paste bar (HomeView "send.paste"): new clipboard content waiting to be sent.
    const paste = el("div.ios-paste", {}, root);
    const pIc = el("div.ios-paste-ic", {}, paste);
    const pSym = sym("paperplane.fill", 17, "#fff", pIc);
    const pImg = el("img", {}, pIc);
    const pCol = el("div.ios-paste-col", {}, paste);
    const pTitle = el("b", {}, pCol);
    const pSub = el("span", {}, pCol);
    const pBtn = el("div.ios-paste-btn", {}, paste);
    sym("doc.on.clipboard.fill", 15, "#fff", pBtn);
    el("span", { text: T.paste }, pBtn);
    // Toast (ToastOverlay): glass capsule above the bar.
    const toast = el("div.ios-toast", {}, root);
    const tSym = sym("paperplane.fill", 15, "var(--iris)", toast);
    const tText = el("span", {}, toast);
    return {
      root, rows, pasteBtn: pBtn, pasteBar: paste, group, box: rowsBox,
      update(t, { pasteState = null, toastState = null } = {}) {
        const lay = A.layout(items, t, () => 66);
        placeRows(rows, lay, t);
        const vis = rows.filter((r) => lay[r.item.id].on);
        set(group, { height: lay.__total.toFixed(1) + "px" });
        // the separator under the last visible row is hidden
        let last = null, ly = -1;
        for (const r of vis) if (lay[r.item.id].y > ly) { ly = lay[r.item.id].y; last = r; }
        for (const r of rows) r.el.classList.toggle("last", r === last);
        if (pasteState) {
          txt(pTitle, pasteState.title); txt(pSub, pasteState.sub);
          if (pasteState.img) { if (pImg.getAttribute("src") !== pasteState.img) pImg.setAttribute("src", pasteState.img); set(pImg, { display: "" }); set(pSym, { display: "none" }); }
          else { set(pImg, { display: "none" }); set(pSym, { display: "" }); }
          const hi = pasteState.fresh || 0;
          set(paste, { "--fresh": hi.toFixed(3), transform: "translateY(" + ((pasteState.y || 0)).toFixed(1) + "px)", opacity: (pasteState.opacity ?? 1).toFixed(3) });
          set(pBtn, { transform: "scale(" + (pasteState.press ? 1 - 0.06 * pasteState.press : 1).toFixed(3) + ")" });
        }
        if (toastState) {
          const on = NC.win(t, toastState.start, toastState.end, 0.01, 0.25);
          const s = spring(t - toastState.start, 0.4, 0.8);
          txt(tText, toastState.text);
          set(tSym, { webkitMaskImage: "url(assets/symbols/" + toastState.symbol + ".png)", maskImage: "url(assets/symbols/" + toastState.symbol + ".png)" });
          set(toast, { display: on > 0 ? "" : "none", opacity: (on > 0 ? Math.min(1, prog(t, toastState.start, toastState.start + 0.1)) * (t > toastState.end ? on : 1) : 0).toFixed(3), transform: "translate(-50%," + ((1 - s) * 18).toFixed(1) + "px) scale(" + (0.9 + 0.1 * Math.min(1, s)).toFixed(3) + ")" });
        } else set(toast, { display: "none" });
      },
      row(id) { return rows.find((r) => r.item.id === id); },
    };
  };
})();

