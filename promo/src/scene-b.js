// Nearclip promo, part two: the four-platform grid, the feature cards, the end card, the timeline (renderAt) and the
// sound cues. Builds on everything scene-a.js made (NC.SCENES). Every frame is a pure function of t.
(function () {
  const { el, set, txt, sym, icon, clamp, lerp, prog, spring, E, win, rect, rnd, mix } = NC;
  const S = NC.SCENES;
  const { b, W, H, V, LANG, IRIS, INK, PAPER, C, T, DEV, TXT, LY, sfx, pan, blur, AUDIO, BLUR, DURATION, list, BASE, caption, scene, t1, t2, t3 } = S;
  const PHOTO = "assets/lisbon.jpg";
  const IDLE = { title: T.idle, sub: T.idleSub };
  const KO = LANG === "ko";

  // A node's box in its device screen's own units (offsets ignore transforms), mapped to stage pixels.
  function off(node, anc) {
    let x = 0, y = 0, n = node;
    while (n && n !== anc) { x += n.offsetLeft; y += n.offsetTop; n = n.offsetParent; }
    return { x, y, w: node.offsetWidth, h: node.offsetHeight };
  }
  function toStage(node, screen) {
    const sr = rect(screen), k = sr.w / screen.offsetWidth, o = off(node, screen);
    const x = sr.x + o.x * k, y = sr.y + o.y * k, w = o.w * k, h = o.h * k;
    return { x, y, w, h, cx: x + w / 2, cy: y + h / 2, k };
  }
  function local(node, screen) {
    const o = off(node, screen);
    return { x: o.x, y: o.y, w: o.w, h: o.h, cx: o.x + o.w / 2, cy: o.y + o.h / 2 };
  }
  const tf = (x, y, s = 1, extra = "") => "translate(" + x.toFixed(2) + "px," + y.toFixed(2) + "px) scale(" + s.toFixed(4) + ")" + extra;

  // A line under a headline: rises a little and fades in.
  function subline(parent, text, { x = 0, y, size, color, align = "left" }) {
    const node = el("div.csub", { text, style: { top: y + "px", fontSize: size + "px", color } }, parent);
    if (align === "center") set(node, { left: "0px", width: W + "px", textAlign: "center" }); else set(node, { left: x + "px" });
    return { node, update(t, at) { const a = E.outCubic(prog(t, at, at + 0.55)); set(node, { opacity: a.toFixed(3), transform: "translateY(" + ((1 - a) * 18).toFixed(1) + "px)" }); } };
  }

  // ================================================================== the four platforms (beats 40–51)
  const SA = scene(PAPER);
  const ALL = { keys: 21.28, ctrl: 21.5, c: 21.62, up: 21.82, win: 21.86, mac: 22.1, android: 22.24, iphone: 22.38 };
  const allRows = (viewer) => list(viewer, [["all1", "now", ALL[viewer]], ["photo", "now"], ["code", "m1"], ["address", "m1"], ...BASE]);
  const others = (self) => ["mac", "win", "android", "iphone"].filter((d) => d !== self).map((d) => ({ dev: d, on: true }));

  function macTile(parent) {
    const root = el("div.tile", {}, parent);
    const scr = el("div.tile-screen", { style: { width: "440px", height: "620px", background: IRIS } }, root);
    const bar = el("div.tile-mbar", {}, scr);
    icon("brand", "mono", 17, el("span.mac-nc", {}, bar));
    sym("wifi", 15, "currentColor", bar);
    sym("battery.100percent", 22, "currentColor", bar);
    el("span.mac-clock", { text: TXT.macClock }, bar);
    const panel = NC.A.macPanel(scr, { T, status: T.connected(3), devices: others("mac"), items: allRows("mac") });
    set(panel.root, { left: "30px", top: "46px" });
    return { root, panel, w: 440, h: 620, place: (x, y, s) => set(root, { transform: tf(x, y, s) }) };
  }
  function winTile(parent) {
    const root = el("div.tile", {}, parent);
    const scr = el("div.tile-screen", { style: { width: "420px", height: "620px", background: "#2a2d3a" } }, root);
    const fly = NC.A.winFlyout(scr, { T, status: T.connected(3), devices: others("win"), items: allRows("win") });
    set(fly.root, { left: "30px", top: "38px" });
    const bar = el("div.tile-tbar", {}, scr);
    const start = el("span.win-tb-btn.win-start", {}, bar);
    for (let i = 0; i < 4; i++) el("i", {}, start);
    icon("f", "search", 20, el("span.win-tb-btn", {}, bar));
    const tray = el("div.win-tray", {}, bar);
    icon("brand", "mono", 18, el("span.win-tray-nc", {}, tray));
    icon("f", "wifi_1", 18, tray);
    const time = el("span.win-clock", {}, tray);
    el("span", { text: TXT.winClock[0] }, time);
    el("span", { text: TXT.winClock[1] }, time);
    return { root, fly, w: 420, h: 620, place: (x, y, s) => set(root, { transform: tf(x, y, s) }) };
  }
  const macT = macTile(SA.world);
  const winT = winTile(SA.world);
  const pxA = NC.D.pixel(SA.world, {});
  const andA = NC.A.androidHome(pxA.app, { T, connected: T.connectedShort(3), devices: others("android"), items: allRows("android") });
  const ipA = NC.D.iphone(SA.world, {});
  const iosA = NC.A.iosHome(ipA.app, { T, status: T.connected(3), statusSub: DEV.name.mac + ", " + DEV.name.android + ", " + DEV.name.win,
    devices: others("iphone"), items: allRows("iphone") });
  const keyCtrlA = NC.X.keycap(SA.top, { label: "Ctrl", w: 132 });
  const keyCA = NC.X.keycap(SA.top, { label: "C", w: 92 });
  const capA = caption(SA.root, V ? ["Mac · Windows", "Android · iPhone", C.all[1]] : C.all, { y: V ? 150 : 76, size: V ? 66 : 64 });

  // Tiles: [kind, node, natural w, natural h]; all are scaled to one height.
  const tilesOrder = V ? [["mac", 0, 0], ["iphone", 1, 0], ["win", 0, 1], ["android", 1, 1]] : [["mac", 0, 0], ["win", 1, 0], ["android", 2, 0], ["iphone", 3, 0]];
  const tileOf = { mac: { n: macT, w: 440, h: 620 }, win: { n: winT, w: 420, h: 620 }, android: { n: pxA, w: pxA.W, h: pxA.H }, iphone: { n: ipA, w: ipA.W, h: ipA.H } };
  const labelOf = { mac: C.labels[0], win: C.labels[1], android: C.labels[2], iphone: C.labels[3] };
  const TILE = {};
  (function layoutTiles() {
    const rowH = V ? 474 : 620, gap = V ? 34 : 44;
    const rows = {};
    for (const [k, col, row] of tilesOrder) (rows[row] = rows[row] || []).push(k);
    const top0 = V ? 492 : 290, rowStep = V ? rowH + 86 : 0;
    for (const row of Object.keys(rows)) {
      const ks = rows[row];
      const ws = ks.map((k) => (tileOf[k].w * rowH) / tileOf[k].h);
      const total = ws.reduce((a, c) => a + c, 0) + gap * (ks.length - 1);
      let x = (W - total) / 2;
      ks.forEach((k, i) => {
        const s = rowH / tileOf[k].h, y = top0 + row * rowStep;
        TILE[k] = { x, y, s, w: ws[i], h: rowH, i: Object.keys(TILE).length };
        x += ws[i] + gap;
      });
    }
  })();
  const labels = {};
  for (const k of Object.keys(TILE)) {
    const L = TILE[k];
    labels[k] = el("div.tile-label", { text: labelOf[k], style: { left: L.x + L.w / 2 + "px", top: (V ? L.y - 44 : L.y + L.h + 30) + "px" } }, SA.root);
  }

  // ================================================================== the feature cards (beats 52–68)
  const CARD = [26, 28, 30, 32];
  const SC = [scene(INK), scene(IRIS), scene(PAPER), scene(INK)];
  const L4 = V ? {
    m1: { head: { y: 300, size: 100 }, sub: { y: 548 }, qr: [540, 1004, 500], ok: [540, 1340] },
    m2: { head: { y: 300, size: 100 }, sub: { y: 548 }, cardL: [64, 840], cardR: [716, 840], pill: [540, 1230] },
    m3: { head: { y: 300, size: 100 }, sub: { y: 548 }, a: [540, 800], b: [540, 1420], vertical: true },
    m4: { head: { y: 250, size: 96 }, sub: { y: 486 }, panel: [270, 640, 1.42] },
  } : {
    m1: { head: { x: 170, y: 372, size: 100 }, sub: { x: 170, y: 640 }, qr: [1350, 524, 440], ok: [1350, 852] },
    m2: { head: { x: 1080, y: 384, size: 92 }, sub: { x: 1080, y: 638 }, cardL: [96, 424], cardR: [664, 424], pill: [544, 760] },
    m3: { head: { y: 150, size: 100 }, sub: { y: 880 }, a: [400, 620], b: [1520, 620] },
    m4: { head: { x: 170, y: 384, size: 92 }, sub: { x: 170, y: 638 }, panel: [1150, 158, 1.42] },
  };
  const HEADC = [["#ffffff", "#9aa5ff"], ["#ffffff", "#ffffff"], [INK, IRIS], ["#ffffff", "#9aa5ff"]];
  const SUBC = ["rgba(255,255,255,0.62)", "rgba(255,255,255,0.8)", "#6b6c75", "rgba(255,255,255,0.62)"];
  const heads = [], subs = [];
  ["m1", "m2", "m3", "m4"].forEach((m, i) => {
    const L = L4[m];
    const centered = V || L.head.x == null;
    heads.push(caption(SC[i].root, C[m], { align: centered ? "center" : "left", x: L.head.x, y: L.head.y, size: L.head.size, color: HEADC[i][0], accent: HEADC[i][1] }));
    subs.push(subline(SC[i].root, C[m + "s"], { x: L.sub.x, y: L.sub.y, size: V ? 34 : 34, color: SUBC[i], align: centered ? "center" : "left" }));
  });

  // m1: QR pairing
  const M1 = (function () {
    const [cx, cy, q] = L4.m1.qr;
    const card = el("div.qr-card", { style: { width: q + "px", height: q + "px" } }, SC[0].world);
    const pad = q * 0.07;
    const qr = el("div.qr", { style: { left: pad + "px", top: pad + "px", width: q - 2 * pad + "px", height: q - 2 * pad + "px" } }, card, NC_ICONS.brand.qr);
    const scan = el("div.qr-scan", { style: { left: pad * 0.6 + "px", width: q - pad * 1.2 + "px" } }, card);
    const br = ["tl", "tr", "bl", "br"].map((c) => el("div.bracket." + c, {}, SC[0].world));
    const ok = el("div.okpill", {}, SC[0].world);
    sym("checkmark", 18, "#fff", el("span.okc", {}, ok));
    el("span", { text: C.joined }, ok);
    return { cx, cy, q, card, qr, scan, br, ok };
  })();

  // m2: another network
  function netCard(parent, drawIcon, name, netSym, net) {
    const root = el("div.netcard", { style: { width: (V ? 300 : 320) + "px" } }, parent);
    drawIcon(el("div.nc-ic", {}, root));
    el("b", { text: name }, root);
    const row = el("div.nc-net", {}, root);
    sym(netSym, 22, "currentColor", row);
    el("span", { text: net }, row);
    return root;
  }
  const M2 = (function () {
    const a = netCard(SC[1].world, (n) => sym("laptopcomputer", 40, "currentColor", n), DEV.name.mac, "wifi", C.home);
    const c = netCard(SC[1].world, (n) => icon("m", "smartphone", 40, n), DEV.name.android, "cellularbars", C.lte);
    const svg = el("svg.netline", { width: W, height: H, viewBox: "0 0 " + W + " " + H }, SC[1].world);
    const path = el("path", { fill: "none", stroke: "rgba(255,255,255,0.7)", "stroke-width": "4", "stroke-linecap": "round", "stroke-dasharray": "2 14" }, svg);
    const maskPath = el("path", { fill: "none", stroke: "#fff", "stroke-width": "10" }, el("mask", { id: "m2mask" }, el("defs", {}, svg)));
    path.setAttribute("mask", "url(#m2mask)");
    const trav = el("div.travel", {}, SC[1].world);
    el("div.tv-ic", {}, trav, NC_ICONS.brand.tile);
    el("span", { text: KO ? "회의는 8시로…" : "Meeting moved…" }, trav);
    const pill = el("div.statuspill", {}, SC[1].world);
    el("i.dot", {}, pill);
    sym("globe", 22, "#fff", pill);
    el("span", { text: C.remote }, pill);
    return { a, c, svg, path, maskPath, trav, pill };
  })();

  // m3: end-to-end encryption
  const PLAIN = TXT.all1;
  const M3 = (function () {
    const devA = el("div.e2e-dev", {}, SC[2].world); icon("f", "desktop", 84, devA);
    const devB = el("div.e2e-dev", {}, SC[2].world); sym("iphone", 78, INK, devB);
    const nA = el("div.e2e-name", { text: DEV.name.win }, SC[2].world);
    const nB = el("div.e2e-name", { text: DEV.name.iphone }, SC[2].world);
    const track = el("div.e2e-track", {}, SC[2].world);
    const pill = el("div.cipher", {}, SC[2].world);
    const lk = el("div.lk", {}, pill);
    const icTile = el("div", { style: { position: "absolute", inset: "0", borderRadius: "50%", overflow: "hidden" } }, lk, NC_ICONS.brand.tile);
    const icLock = sym("lock.fill", 20, "#fff", lk);
    const icOk = sym("checkmark", 18, "#fff", lk);
    set(icLock, { position: "absolute" }); set(icOk, { position: "absolute" });
    const box = el("div", { style: { position: "relative", height: "30px" } }, pill);
    const plain = el("span.ct", { text: PLAIN, style: { position: "absolute", left: "0", top: "2px" } }, box);
    const ciph = el("span.ct.mono", { style: { position: "absolute", left: "0", top: "2px" } }, box);
    return { devA, devB, nA, nB, track, pill, lk, icTile, icLock, icOk, box, plain, ciph, w: 0 };
  })();
  const HEX = "0123456789abcdef";
  function cipherText(seed, n) {
    let s = "";
    for (let i = 0; i < n; i++) s += (i && i % 4 === 0 ? " " : "") + HEX[Math.floor(rnd(seed * 31.7 + i * 7.13) * 16)];
    return s;
  }

  // m4: one history, search and pin
  const M4 = (function () {
    const items = list("mac", [["all1", "m1"], ["photo", "m1"], ["code", "m12"], ["address", "m12"], ...BASE]);
    const panel = NC.A.macPanel(SC[3].world, { T, status: T.connected(3), devices: others("mac"), items });
    set(panel.root, { transformOrigin: "0 0" });
    items.forEach((it, i) => { if (i > 0) it.out = 32.55; });
    const pin = el("div.pinbadge", {}, SC[3].world);
    sym("pin.fill", 13, "#fff", pin);
    return { panel, items, pin };
  })();

  // ================================================================== the end card (beats 68–78)
  const SF = scene(PAPER);
  const FIN = V ? { icon: [540, 640, 280], name: 846, tag: 1034, chips: 1140, by: 1424, nameSize: 140, tagSize: 50 } : { icon: [960, 328, 240], name: 496, tag: 664, chips: 768, by: 968, nameSize: 132, tagSize: 46 };
  const morph = el("div.morph", {}, SF.root);
  const glyph = el("div.fin-glyph", {}, SF.root, NC_ICONS.brand.glyph);
  const finNameMask = el("div.cap-mask", { style: { position: "absolute", left: "0", right: "0", top: FIN.name + "px" } }, SF.root);
  const finName = el("div.fin-name", { text: "Nearclip", style: { position: "relative", fontSize: FIN.nameSize + "px" } }, finNameMask);
  const finTag = el("div.fin-tag", { text: C.tagline, style: { top: FIN.tag + "px", fontSize: FIN.tagSize + "px" } }, SF.root);
  const chipRow = el("div.fin-chips", { style: { top: FIN.chips + "px" } }, SF.root);
  const finChips = [["sym", "laptopcomputer", "macOS"], ["f", "desktop", "Windows"], ["m", "smartphone", "Android"], ["sym", "iphone", "iOS"]].map(([kind, name, label]) => {
    const c = el("div.fin-chip", {}, chipRow);
    const ic = el("span.fc-ic", {}, c);
    if (kind === "sym") sym(name, 22, "currentColor", ic); else icon(kind, name, 24, ic);
    el("span", { text: label }, c);
    return c;
  });
  const finBy = el("div.fin-by", { style: { top: FIN.by + "px" } }, SF.root, "by <b>ivLis</b><span>STUDIO</span>");

  // ================================================================== hook: rolling platform names
  const SH = S.SH, hookBox = SH.querySelector(".hook-box");
  const STEPS = S.SEQ.map((s) => b(s[0]));
  S.slots.forEach((sl, k) => {
    sl.pill.textContent = "";
    sl.roll = el("div.hook-roll", {}, sl.pill);
    sl.seq = S.SEQ.map((s) => S.PLATS[s[1][k]]);
    sl.words = sl.seq.map((w) => el("span.hook-word", { text: w }, sl.roll));
  });

  // ================================================================== timeline
  const SCENES = [[S.S1.root, 3.0, 9.0], [S.S2.root, 8.45, 15.0], [S.S3.root, 15.0, 20.0], [SA.root, 20.0, 26.0],
    [SC[0].root, 26.0, 28.0], [SC[1].root, 28.0, 30.0], [SC[2].root, 30.0, 32.0], [SC[3].root, 32.0, 33.62], [SF.root, 33.6, 1e9]];
  const M = {};

  function hook(t) {
    set(SH, { display: t < 3.3 ? "block" : "none", background: t < 3.05 ? IRIS : "transparent" });
    set(hookBox, { transform: "translateY(-50%) scale(" + (1 + 0.035 * E.outQuad(prog(t, 0, 3.05))).toFixed(4) + ")" });
    S.hookLines.forEach((h, i) => {
      const a = E.outExpo(prog(t, 0.04 + 0.09 * i, 0.78 + 0.09 * i));
      const o = E.inCubic(prog(t, 2.88 + 0.035 * i, 3.16 + 0.035 * i));
      set(h.line, { transform: "translateY(" + ((1 - a) * 112 - o * 118).toFixed(2) + "%)" });
    });
    for (const sl of S.slots) {
      let p = 0;
      for (let i = 1; i < STEPS.length; i++) p += clamp(spring(t - STEPS[i], 0.34, 0.8), 0, 1.06);
      const n = sl.widths.length - 1;
      const i0 = Math.max(0, Math.min(n, Math.floor(p)));
      const w = lerp(sl.widths[i0], sl.widths[Math.min(n, i0 + 1)], clamp(p - i0));
      set(sl.pill, { width: w.toFixed(1) + "px" });
      set(sl.roll, { transform: "translateY(" + (-p * sl.wordH).toFixed(2) + "px)" });
    }
  }

  function d1(t) {
    const L = LY.d1;
    S.pc1.place(...L.pc);
    S.mac1.place(...L.mac);
    const u = E.outCubic(prog(t, 3.02, 4.25));
    const z = Math.pow(LY.zoom, 1 - u);
    const fx = lerp(M.macC[0], W / 2, u), fy = lerp(M.macC[1], H / 2, u);
    const push = -90 * E.inOutCubic(prog(t, 8.45, 8.95));
    set(S.S1.world, { transform: "translate(" + (W / 2 - fx * z + push).toFixed(2) + "px," + (H / 2 - fy * z).toFixed(2) + "px) scale(" + z.toFixed(5) + ")" });
    const wn = spring(t - t1.win, 0.42, 0.8);
    set(S.note1.root, { opacity: t < t1.win ? "0" : Math.min(1, (t - t1.win) / 0.1).toFixed(3), transform: "scale(" + (0.94 + 0.06 * Math.min(1.02, wn)).toFixed(4) + ")", transformOrigin: "50% 60%" });
    const selU = E.inOutCubic(prog(t, t1.dragA, t1.dragB));
    set(S.note1.refs.hl, { width: (selU * (M.selW + 4)).toFixed(1) + "px" });
    const tr = toStage(M.selText, S.mac1.screen);
    const wr = toStage(S.note1.root, S.mac1.screen);
    const x0 = tr.x - 2, x1 = tr.x + tr.w + 2;
    const mv = E.inOutCubic(prog(t, t1.ptr, t1.ptr + 0.3));
    let p = [lerp(wr.x + wr.w * 0.8, x0, mv), lerp(wr.y + wr.h * 0.86, tr.cy, mv)];
    if (t >= t1.dragA) p = [lerp(x0, x1, selU), tr.cy];
    S.ptr1.update(t, { x: p[0], y: p[1], show: t >= t1.ptr && t < 8.7, beam: mv > 0.7, s: tr.k / 0.74 });
    const km = LY.keys.d1mac, kp = LY.keys.d1pc;
    S.keyCmd1.update(t, { show: t1.cmd - 0.22, hide: t1.up + 0.42, down: t1.cmd, up: t1.up, x: km[0] - 105, y: km[1] });
    S.keyC1.update(t, { show: t1.cmd - 0.16, hide: t1.up + 0.46, down: t1.c, up: t1.up, x: km[0] + 13, y: km[1] });
    const pr = rect(S.pc1.screen), pk = pr.w / S.pc1.screen.offsetWidth;
    const toast = [pr.x + pr.w - (12 + 172) * pk, pr.y + pr.h - (60 + 34) * pk];
    S.chip1.update(t, { start: t1.launch, end: t1.land, from: [tr.cx, tr.cy], to: toast, text: TXT.address, arc: V ? -150 : -190, toScale: 0.6 });
    S.winToast1.update(t, { start: t1.land, end: t1.land + 2.0, from: T.copiedFrom(DEV.name.mac), preview: TXT.address, dev: "mac" });
    S.keyCtrl1.update(t, { show: t1.ctrl - 0.24, hide: t1.vup + 0.42, down: t1.ctrl, up: t1.vup, x: kp[0] - 119, y: kp[1] });
    S.keyV1.update(t, { show: t1.ctrl - 0.18, hide: t1.vup + 0.46, down: t1.v, up: t1.vup, x: kp[0] + 27, y: kp[1] });
    S.map1.update(t, { pasteAt: t1.paste, pinAt: t1.pin });
    S.cap1.update(t, [4.3, t1.paste + 0.04], 8.5, 0.3);
  }

  function d2(t) {
    const L = LY.d2;
    S.mac2.place(...L.mac);
    S.px2.place(...L.phone);
    const u = E.inOutCubic(prog(t, 8.45, 8.95));
    set(S.S2.root, { clipPath: u < 1 ? "inset(0px 0px 0px " + ((1 - u) * W).toFixed(1) + "px)" : "none" });
    set(S.S2.world, { transform: "translateX(" + ((1 - u) * 170).toFixed(1) + "px)" });
    S.sms.update(t, { selectAt: t2.select, tapAt: t2.tap });
    const code = local(S.sms.code, S.px2.screen), send = M.sendLocal;
    if (t < 10.2) S.touch2.update(t, { x: code.cx, y: code.cy, show: 9.42, hide: 10.1, down: t2.down, up: 10.04, long: true });
    else S.touch2.update(t, { x: send.cx, y: send.cy, show: 10.36, hide: 10.86, down: 10.58, up: 10.7 });
    S.andToast2.update(t, { start: 10.74, end: 12.2, text: T.sent(3) });
    const sr = rect(S.px2.screen), ps = sr.w / S.px2.screen.offsetWidth;
    const from = [sr.x + send.cx * ps, sr.y + send.cy * ps];
    const mr = rect(S.mac2.screen), mk = mr.w / S.mac2.screen.offsetWidth;
    const to = [mr.x + mr.w - (14 + 160) * mk, mr.y + (40 + 26) * mk];
    S.chip2.update(t, { start: t2.launch, end: t2.land, from, to, text: "482913", arc: V ? -160 : -230, toScale: 0.6 });
    S.macToast2.update(t, { start: t2.land, end: t2.land + 2.3, from: T.copiedFrom(DEV.name.android), preview: "482913", dev: "android" });
    const kc = LY.keys.d2, kx = kc[0] - 105;
    S.keyCmd2.update(t, { show: t2.cmd - 0.24, hide: t2.up + 0.42, down: t2.cmd, up: t2.up, x: kx, y: kc[1] });
    S.keyV2.update(t, { show: t2.cmd - 0.18, hide: t2.up + 0.46, down: t2.v, up: t2.up, x: kx + 118, y: kc[1] });
    S.browser2.update(t, { code: "482913", pasteAt: t2.paste, okAt: t2.ok });
    const btn = M.btnLocal, bx = M.boxesLocal;
    const mv = E.inOutCubic(prog(t, 12.42, 12.9));
    const px = lerp(bx.x + bx.w + 40, btn.cx + 18, mv), py = lerp(bx.cy + 30, btn.cy + 6, mv);
    const press = win(t, 12.93, 13.02, 0.04, 0.1);
    S.ptr2.update(t, { x: px, y: py, show: t >= 12.36 && t < 14.6, s: 1.15 * (1 - 0.1 * press) });
    S.cap2.update(t, [9.15, t2.paste + 0.05], 14.55, 0.3);
  }

  function d3(t) {
    const L = LY.d3;
    S.pc3.place(...L.pc);
    S.ip3.place(...L.phone);
    const k = 1 + 0.035 * (1 - clamp(spring(t - 15.0, 0.55, 0.9), 0, 1.1));
    set(S.S3.world, { transform: "translate(" + (W / 2 * (1 - k)).toFixed(2) + "px," + (H / 2 * (1 - k)).toFixed(2) + "px) scale(" + k.toFixed(5) + ")" });
    const sent = t >= t3.sent + 0.2;
    const fresh = E.outCubic(prog(t, t3.fresh, t3.fresh + 0.25)) * (1 - 0.55 * prog(t, t3.fresh + 0.55, t3.fresh + 1.0));
    const press = win(t, 15.68, 15.8, 0.05, 0.12);
    S.ios3.update(t, { pasteState: sent ? IDLE : { title: T.newImage, sub: T.tapPaste, img: PHOTO, fresh, press }, toastState: { start: t3.sent, end: 17.5, text: T.sent(3), symbol: "paperplane.fill" } });
    const pb = local(S.ios3.pasteBtn, S.ip3.screen);
    S.touch3.update(t, { x: pb.cx, y: pb.cy, show: 15.42, hide: 15.98, down: 15.68, up: 15.8 });
    const pi = toStage(S.ios3.pasteBar, S.ip3.screen);
    const pr = rect(S.pc3.screen), pk = pr.w / S.pc3.screen.offsetWidth;
    const to = [pr.x + pr.w - (12 + 172) * pk, pr.y + pr.h - (60 + 34) * pk];
    S.chip3.update(t, { start: t3.launch, end: t3.land, from: [pi.x + 34 * pi.k, pi.cy], to, image: PHOTO, arc: V ? -170 : -220, toScale: 0.42 });
    S.winToast3.update(t, { start: t3.land, end: t3.land + 2.0, from: T.copiedFrom(DEV.name.iphone), preview: T.image + " · 4032×3024", img: PHOTO, dev: "iphone" });
    const kc = LY.keys.d3, kx = kc[0] - 119;
    S.keyCtrl3.update(t, { show: t3.ctrl - 0.24, hide: t3.up + 0.42, down: t3.ctrl, up: t3.up, x: kx, y: kc[1] });
    S.keyV3.update(t, { show: t3.ctrl - 0.18, hide: t3.up + 0.46, down: t3.v, up: t3.up, x: kx + 146, y: kc[1] });
    S.chat3.update(t, { pasteAt: t3.paste, replyAt: t3.reply });
    S.cap3.update(t, [15.15, t3.paste + 0.05], 19.55, 0.3);
  }

  function all(t) {
    for (const k of Object.keys(TILE)) {
      const L = TILE[k], ti = 20.0 + 0.06 * L.i;
      const s = clamp(spring(t - ti, 0.46, 0.8), 0, 1.2);
      const dy = (1 - s) * (V ? 220 : 260);
      const a = prog(t, ti, ti + 0.06);
      const node = tileOf[k].n;
      node.place(L.x, L.y + dy, L.s);
      set(node.root, { opacity: a.toFixed(3) });
      set(labels[k], { opacity: prog(t, ti + 0.22, ti + 0.5).toFixed(3) });
    }
    macT.panel.update(t, {});
    winT.fly.update(t, {});
    andA.update(t);
    iosA.update(t, { pasteState: IDLE, toastState: null });
    const L = TILE.win, ks = V ? 0.78 : 0.86;
    const kx = L.x + L.w / 2 - (238 * ks) / 2, ky = L.y + L.h - (V ? 150 : 170);
    keyCtrlA.update(t, { show: ALL.keys, hide: 22.3, down: ALL.ctrl, up: ALL.up, x: kx, y: ky, s: ks });
    keyCA.update(t, { show: ALL.keys + 0.06, hide: 22.34, down: ALL.c, up: ALL.up, x: kx + 146 * ks, y: ky, s: ks });
    capA.update(t, V ? [20.12, 20.26, 22.5] : [20.12, 22.5], 25.62, 0.3);
  }

  function m1(t) {
    const t0 = CARD[0], m = M1;
    heads[0].update(t, [t0 + 0.04, t0 + 0.14]);
    subs[0].update(t, t0 + 0.42);
    const s = clamp(spring(t - (t0 + 0.06), 0.5, 0.74), 0, 1.2);
    set(m.card, { transform: tf(m.cx - m.q / 2, m.cy - m.q / 2, 0.82 + 0.18 * s), opacity: prog(t, t0 + 0.06, t0 + 0.16).toFixed(3), transformOrigin: "50% 50%" });
    const r = E.outCubic(prog(t, t0 + 0.16, t0 + 0.56));
    set(m.qr, { clipPath: "inset(0px 0px " + ((1 - r) * 100).toFixed(2) + "% 0px)" });
    const bs = E.outBack(prog(t, t0 + 0.52, t0 + 0.8));
    const gap = 30 + 70 * (1 - bs), done = t >= t0 + 1.12;
    const color = done ? "#2fbf71" : "#ffffff";
    const ba = prog(t, t0 + 0.5, t0 + 0.62);
    const h = m.q / 2 + gap;
    [[-1, -1], [1, -1], [-1, 1], [1, 1]].forEach(([sx, sy], i) => {
      set(m.br[i], { opacity: ba.toFixed(3), borderColor: color, transform: tf(m.cx + sx * h - (sx > 0 ? 64 : 0), m.cy + sy * h - (sy > 0 ? 64 : 0)) });
    });
    const sc = prog(t, t0 + 0.8, t0 + 1.1);
    set(m.scan, { top: (m.q * 0.06 + sc * m.q * 0.86).toFixed(1) + "px", opacity: (win(t, t0 + 0.8, t0 + 1.05, 0.06, 0.08)).toFixed(3) });
    const os = clamp(spring(t - (t0 + 1.12), 0.42, 0.66), 0, 1.3);
    const [ox, oy] = L4.m1.ok;
    set(m.ok, { opacity: prog(t, t0 + 1.12, t0 + 1.22).toFixed(3), transform: "translate(" + (ox - M.okW / 2).toFixed(1) + "px," + (oy - 32 + (1 - Math.min(1, os)) * 16).toFixed(1) + "px) scale(" + (0.7 + 0.3 * os).toFixed(4) + ")" });
  }

  function m2(t) {
    const t0 = CARD[1], m = M2, L = L4.m2;
    heads[1].update(t, [t0 + 0.04, t0 + 0.14]);
    subs[1].update(t, t0 + 0.42);
    const sa = clamp(spring(t - (t0 + 0.05), 0.5, 0.78), 0, 1.2), sc = clamp(spring(t - (t0 + 0.12), 0.5, 0.78), 0, 1.2);
    const cw = M.netW, ch = M.netH;
    set(m.a, { transform: tf(L.cardL[0] - (1 - sa) * 120, L.cardL[1]), opacity: prog(t, t0 + 0.05, t0 + 0.16).toFixed(3) });
    const arrive = t >= t0 + 1.24 ? 1 + 0.045 * Math.sin(Math.PI * prog(t, t0 + 1.24, t0 + 1.46)) : 1;
    set(m.c, { transform: tf(L.cardR[0] + (1 - sc) * 120, L.cardR[1], arrive), opacity: prog(t, t0 + 0.12, t0 + 0.23).toFixed(3) });
    const p0 = [L.cardL[0] + cw, L.cardL[1] + ch * 0.36], p2 = [L.cardR[0], L.cardR[1] + ch * 0.36];
    const p1 = [(p0[0] + p2[0]) / 2, Math.min(p0[1], p2[1]) - (V ? 150 : 170)];
    const d = "M" + p0[0] + " " + p0[1] + " Q" + p1[0] + " " + p1[1] + " " + p2[0] + " " + p2[1];
    NC.attr(m.path, "d", d);
    NC.attr(m.maskPath, "d", d);
    const len = M.arcLen || (M.arcLen = m.maskPath.getTotalLength());
    const dr = E.inOutCubic(prog(t, t0 + 0.3, t0 + 0.66));
    NC.attr(m.maskPath, "stroke-dasharray", (dr * len).toFixed(1) + " " + (len + 10).toFixed(1));
    const tv = E.inOutCubic(prog(t, t0 + 0.7, t0 + 1.24));
    const [x, y] = NC.bez(p0, p1, p2, tv);
    const ta = win(t, t0 + 0.64, t0 + 1.22, 0.1, 0.12);
    set(m.trav, { opacity: ta.toFixed(3), transform: "translate(" + x.toFixed(1) + "px," + (y - 6).toFixed(1) + "px) translate(-50%,-50%) scale(" + (0.85 + 0.15 * ta).toFixed(3) + ")" });
    const ps = clamp(spring(t - (t0 + 1.26), 0.42, 0.66), 0, 1.3);
    set(m.pill, { opacity: prog(t, t0 + 1.26, t0 + 1.36).toFixed(3), transform: "translate(" + (L.pill[0] - M.pillW / 2).toFixed(1) + "px," + (L.pill[1] - 30 + (1 - Math.min(1, ps)) * 14).toFixed(1) + "px) scale(" + (0.72 + 0.28 * ps).toFixed(4) + ")" });
  }

  function m3(t) {
    const t0 = CARD[2], m = M3, L = L4.m3;
    heads[2].update(t, [t0 + 0.04, t0 + 0.14]);
    subs[2].update(t, t0 + 0.42);
    const sa = clamp(spring(t - (t0 + 0.06), 0.46, 0.7), 0, 1.25), sb = clamp(spring(t - (t0 + 0.13), 0.46, 0.7), 0, 1.25);
    const R = 90;
    set(m.devA, { transform: tf(L.a[0] - R, L.a[1] - R, 0.6 + 0.4 * sa), opacity: prog(t, t0 + 0.06, t0 + 0.14).toFixed(3) });
    set(m.devB, { transform: tf(L.b[0] - R, L.b[1] - R, 0.6 + 0.4 * sb), opacity: prog(t, t0 + 0.13, t0 + 0.21).toFixed(3) });
    const na = prog(t, t0 + 0.2, t0 + 0.4);
    if (L.vertical) {
      set(m.nA, { transform: "translate(" + (L.a[0] + R + 26) + "px," + (L.a[1] - 12) + "px)", opacity: na.toFixed(3) });
      set(m.nB, { transform: "translate(" + (L.b[0] + R + 26) + "px," + (L.b[1] - 12) + "px)", opacity: na.toFixed(3) });
    } else {
      set(m.nA, { transform: "translate(" + L.a[0] + "px," + (L.a[1] + R + 26) + "px) translateX(-50%)", opacity: na.toFixed(3) });
      set(m.nB, { transform: "translate(" + L.b[0] + "px," + (L.b[1] + R + 26) + "px) translateX(-50%)", opacity: na.toFixed(3) });
    }
    const tk = E.inOutCubic(prog(t, t0 + 0.18, t0 + 0.46));
    const start = L.vertical ? [L.a[0], L.a[1] + R + 70] : [L.a[0] + R + 36 + M.ciW / 2, L.a[1]];
    const end = L.vertical ? [L.b[0], L.b[1] - R - 70] : [L.b[0] - R - 36 - M.ciW / 2, L.b[1]];
    if (L.vertical) set(m.track, { width: "4px", height: (L.b[1] - L.a[1] - 2 * R) + "px", transform: "translate(" + (L.a[0] - 2) + "px," + (L.a[1] + R) + "px) scaleY(" + tk.toFixed(4) + ")", transformOrigin: "50% 0" });
    else set(m.track, { width: (L.b[0] - L.a[0] - 2 * R) + "px", transform: "translate(" + (L.a[0] + R) + "px," + (L.a[1] - 2) + "px) scaleX(" + tk.toFixed(4) + ")" });
    const mv = E.inOutCubic(prog(t, t0 + 0.62, t0 + 1.3));
    const x = lerp(start[0], end[0], mv), y = lerp(start[1], end[1], mv);
    const pa = prog(t, t0 + 0.32, t0 + 0.44);
    const pop = clamp(spring(t - (t0 + 0.32), 0.4, 0.7), 0, 1.2);
    set(m.pill, { opacity: pa.toFixed(3), transform: "translate(" + x.toFixed(1) + "px," + y.toFixed(1) + "px) translate(-50%,-50%) scale(" + (0.8 + 0.2 * pop).toFixed(4) + ")" });
    const enc = E.inOutCubic(prog(t, t0 + 0.5, t0 + 0.72)), dec = E.inOutCubic(prog(t, t0 + 1.3, t0 + 1.52));
    const wave = enc * (1 - dec);
    set(m.plain, { clipPath: "inset(0px 0px 0px " + (wave * 100).toFixed(2) + "%)" });
    set(m.ciph, { clipPath: "inset(0px " + ((1 - wave) * 100).toFixed(2) + "% 0px 0px)" });
    txt(m.ciph, cipherText(Math.floor(t * 24), M.ciN));
    const locked = t >= t0 + 0.5 && t < t0 + 1.3, done = t >= t0 + 1.3;
    set(m.icTile, { opacity: locked || done ? "0" : "1" });
    set(m.icLock, { opacity: locked ? "1" : "0", transform: "scale(" + (locked ? 0.7 + 0.3 * clamp(spring(t - (t0 + 0.5), 0.35, 0.6), 0, 1.3) : 1).toFixed(3) + ")" });
    set(m.icOk, { opacity: done ? "1" : "0", transform: "scale(" + (done ? 0.6 + 0.4 * clamp(spring(t - (t0 + 1.3), 0.35, 0.6), 0, 1.3) : 1).toFixed(3) + ")" });
    set(m.lk, { background: done ? "#2fbf71" : IRIS });
  }

  function m4(t) {
    const t0 = CARD[3], m = M4, L = L4.m4;
    heads[3].update(t, [t0 + 0.04, t0 + 0.14]);
    subs[3].update(t, t0 + 0.4);
    const [px, py, ps] = L.panel;
    const s = clamp(spring(t - (t0 + 0.05), 0.5, 0.8), 0, 1.15);
    const out = E.inCubic(prog(t, 33.34, 33.6));
    set(m.panel.root, { transform: tf(px + (1 - s) * (V ? 0 : 90), py + (V ? (1 - s) * 90 : 0), ps * (1 - 0.1 * out)), opacity: (prog(t, t0 + 0.05, t0 + 0.15) * (1 - out)).toFixed(3) });
    set(heads[3].box, { opacity: (1 - out).toFixed(3) });
    set(subs[3].node, { opacity: Math.min(1 - out, E.outCubic(prog(t, t0 + 0.4, t0 + 0.95))).toFixed(3) });
    const typed = M.typeAt.filter((a) => t >= a).length;
    m.panel.update(t, { query: C.query.slice(0, typed), focus: t >= t0 + 0.12, select: t >= 32.62 ? m.items[0].id : null });
    const row = toStage(m.panel.box, m.panel.root);
    const pp = clamp(spring(t - 32.85, 0.38, 0.6), 0, 1.3);
    set(m.pin, { opacity: (prog(t, 32.85, 32.92) * (1 - out)).toFixed(3), transform: "translate(" + (row.x + row.w - 78 * row.k).toFixed(1) + "px," + (row.y + 12 * row.k).toFixed(1) + "px) scale(" + (pp * row.k * 1.0).toFixed(4) + ")" });
  }

  function fin(t) {
    const [cx, cy, I] = FIN.icon;
    const s = spring(t - 33.6, 0.62, 0.76);
    const w = lerp(W, I, s), h = lerp(H, I, s);
    const rad = lerp(0, I * 0.225, clamp(s));
    set(morph, { left: (cx - w / 2 + (1 - clamp(s)) * (W / 2 - cx)).toFixed(2) + "px", top: (cy - h / 2 + (1 - clamp(s)) * (H / 2 - cy)).toFixed(2) + "px", width: w.toFixed(2) + "px", height: h.toFixed(2) + "px",
      borderRadius: rad.toFixed(2) + "px", background: mix(INK, IRIS, E.inOutCubic(prog(t, 33.62, 33.95))) });
    const g = clamp(spring(t - 33.9, 0.45, 0.62), 0, 1.25);
    set(glyph, { width: I + "px", height: I + "px", left: (cx - I / 2) + "px", top: (cy - I / 2) + "px", opacity: prog(t, 33.9, 34.02).toFixed(3), transform: "scale(" + (0.55 + 0.45 * g).toFixed(4) + ")" });
    const na = E.outExpo(prog(t, 34.28, 35.0));
    set(finName, { transform: "translateY(" + ((1 - na) * 108).toFixed(2) + "%)" });
    const ta = E.outCubic(prog(t, 34.62, 35.1));
    set(finTag, { opacity: ta.toFixed(3), transform: "translateY(" + ((1 - ta) * 20).toFixed(1) + "px)" });
    finChips.forEach((c, i) => {
      const at = 35.02 + 0.085 * i, cs = clamp(spring(t - at, 0.42, 0.66), 0, 1.3);
      set(c, { opacity: prog(t, at, at + 0.1).toFixed(3), transform: "translateY(" + ((1 - Math.min(1, cs)) * 18).toFixed(1) + "px) scale(" + (0.7 + 0.3 * cs).toFixed(4) + ")" });
    });
    const ba = E.outCubic(prog(t, 35.6, 36.1));
    set(finBy, { opacity: ba.toFixed(3), transform: "translateY(" + ((1 - ba) * 12).toFixed(1) + "px)" });
  }

  function renderAt(t) {
    for (const [node, a, z] of SCENES) set(node, { display: t >= a && t < z ? "block" : "none" });
    hook(t);
    if (t >= 3.0 && t < 9.0) d1(t);
    if (t >= 8.45 && t < 15.0) d2(t);
    if (t >= 15.0 && t < 20.0) d3(t);
    if (t >= 20.0 && t < 26.0) all(t);
    if (t >= 26.0 && t < 28.0) m1(t);
    if (t >= 28.0 && t < 30.0) m2(t);
    if (t >= 30.0 && t < 32.0) m3(t);
    if (t >= 32.0 && t < 33.62) m4(t);
    if (t >= 33.6) fin(t);
  }

  // ================================================================== sound cues and motion blur, from the timeline constants
  M.typeAt = C.query.split("").map((_, i) => 32.24 + i * (KO ? 0.13 : 0.075));
  [1.0, 1.5, 2.0, 2.5].forEach((tt, i) => sfx("roll", tt, { i }));
  sfx("hookout", 2.9);
  sfx("zoomout", 3.05);
  sfx("open", t1.win, { pan: -0.3 });
  sfx("click", t1.dragA, { pan: -0.3 });
  sfx("select", t1.dragB, { pan: -0.25 });
  sfx("key", t1.cmd, { big: true });
  sfx("key", t1.c);
  sfx("fly", t1.launch, { from: -0.35, to: 0.55 });
  sfx("land", t1.land, { pan: 0.55 });
  sfx("toast", t1.land + 0.02, { pan: 0.55 });
  sfx("key", t1.ctrl, { big: true });
  sfx("key", t1.v);
  sfx("paste", t1.paste, { pan: 0.4 });
  sfx("pindrop", t1.pin, { pan: 0.45 });
  sfx("wipe", 8.45);
  sfx("tap", t2.down, { pan: -0.55, long: true });
  sfx("select", t2.select, { pan: -0.55 });
  sfx("tap", 10.58, { pan: -0.55 });
  sfx("toast", 10.74, { pan: -0.55 });
  sfx("fly", t2.launch, { from: -0.55, to: 0.5 });
  sfx("land", t2.land, { pan: 0.5 });
  sfx("toast", t2.land + 0.02, { pan: 0.5 });
  sfx("key", t2.cmd, { big: true });
  sfx("key", t2.v);
  sfx("digits", t2.paste, { pan: 0.15 });
  sfx("click", 12.94, { pan: 0.2 });
  sfx("ok", t2.ok, { pan: 0.2 });
  sfx("fresh", t3.fresh, { pan: -0.5 });
  sfx("tap", 15.68, { pan: -0.5 });
  sfx("toast", t3.sent, { pan: -0.5 });
  sfx("fly", t3.launch, { from: -0.5, to: 0.55 });
  sfx("land", t3.land, { pan: 0.55 });
  sfx("toast", t3.land + 0.02, { pan: 0.55 });
  sfx("key", t3.ctrl, { big: true });
  sfx("key", t3.v);
  sfx("bubble", t3.paste, { pan: 0.3 });
  sfx("reply", t3.reply, { pan: 0.25 });
  [0, 1, 2, 3].forEach((i) => sfx("tile", 20.0 + 0.06 * i, { i, pan: [-0.55, -0.18, 0.18, 0.55][i] }));
  sfx("key", ALL.ctrl, { big: true });
  sfx("key", ALL.c);
  const allPan = (k) => (TILE[k].x + TILE[k].w / 2) / W * 1.2 - 0.6;
  [["win", 0], ["mac", 1], ["android", 2], ["iphone", 3]].forEach(([k, i]) => sfx("receive", ALL[k], { i, pan: allPan(k) }));
  CARD.forEach((tt, i) => sfx("card", tt, { i }));
  sfx("qr", 26.16);
  sfx("bracket", 26.6);
  sfx("scan", 26.8);
  sfx("ok", 27.12);
  sfx("draw", 28.3);
  sfx("fly", 28.7, { from: -0.45, to: 0.05, soft: true });
  sfx("land", 29.24, { pan: 0.05 });
  sfx("pop", 29.26);
  sfx("lock", 30.5);
  sfx("scramble", 30.5, { dur: 0.8 });
  sfx("unlock", 31.3);
  sfx("ok", 31.52);
  M.typeAt.forEach((tt) => sfx("type", tt));
  sfx("filter", 32.55);
  sfx("pin", 32.85);
  sfx("morph", 33.6);
  sfx("logo", 34.0);
  sfx("name", 34.28);
  sfx("tag", 34.62);
  [0, 1, 2, 3].forEach((i) => sfx("chip", 35.02 + 0.085 * i, { i }));
  blur(3.0, 4.25, 6);
  blur(t1.launch - 0.25, t1.land + 0.06, 5);
  blur(8.4, 9.0, 6);
  blur(t2.launch - 0.25, t2.land + 0.06, 5);
  blur(t3.launch - 0.25, t3.land + 0.06, 5);
  blur(t1.pin - 0.02, t1.pin + 0.3, 4);
  blur(20.0, 20.7, 5);
  blur(28.66, 29.3, 4);
  blur(30.6, 31.35, 4);
  blur(33.55, 34.3, 6);

  window.renderAt = renderAt;
  window.DURATION = DURATION;
  window.AUDIO_EVENTS = AUDIO.sort((a, c) => a.t - c.t);
  window.MOTION_BLUR = BLUR;
  window.MUSIC = { bpm: 120, bars: { hook: 0, demos: 2, all: 10, cards: 13, end: 17 }, duration: DURATION };

  // ================================================================== ready: fonts, images, masks, measurements, warm-up
  const raf2 = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  window.ready = (async () => {
    const faces = ["700 64px Pretendard", "600 64px Pretendard", "500 64px Pretendard", "400 16px 'Segoe UI W'", "600 16px 'Segoe UI W'", "300 16px 'Segoe UI W'",
      "400 16px 'Malgun W'", "700 16px 'Malgun W'", "400 16px 'Roboto A'", "500 16px 'Roboto A'"];
    await Promise.all(faces.map((f) => document.fonts.load(f, "가A1").catch(() => null)));
    await document.fonts.ready;
    const urls = new Set(["iphone", "laptopcomputer", "pc", "paperplane.fill"].map((n) => "assets/symbols/" + n + ".png"));
    document.querySelectorAll(".sym").forEach((n) => { const m = /url\("?([^")]+)"?\)/.exec(n.style.maskImage || n.style.webkitMaskImage || ""); if (m) urls.add(m[1]); });
    await Promise.all([...urls].map((u) => new Promise((r) => { const im = new Image(); im.onload = im.onerror = r; im.src = u; })));
    await Promise.all([...document.images].map((im) => (im.getAttribute("src") ? im.decode().catch(() => null) : null)));
    // measurements (layout units, unaffected by transforms): everything shown once, renderAt hides it again
    const show = (node) => set(node, { display: "block" });
    for (const [node] of SCENES) show(node);
    show(SH);
    for (const sl of S.slots) { sl.widths = sl.words.map((w) => w.offsetWidth); sl.wordH = sl.words[0].offsetHeight; }
    M.selText = S.note1.refs.sel.lastChild;
    M.selW = M.selText.offsetWidth;
    const L1 = LY.d1;
    M.macC = [L1.mac[0] + (S.mac1.B + S.mac1.SW / 2) * L1.mac[2], L1.mac[1] + (S.mac1.B + S.mac1.SH / 2) * L1.mac[2]];
    const tb = S.sms.toolbar, it = S.sms.sendItem;
    M.sendLocal = { cx: tb.offsetLeft - tb.offsetWidth / 2 + it.offsetLeft + it.offsetWidth / 2, cy: tb.offsetTop + it.offsetTop + it.offsetHeight / 2 };
    M.btnLocal = local(S.browser2.btn, S.mac2.screen);
    M.boxesLocal = local(S.browser2.boxes, S.mac2.screen);
    M.okW = M1.ok.offsetWidth;
    M.pillW = M2.pill.offsetWidth; M.netW = M2.a.offsetWidth; M.netH = M2.a.offsetHeight;
    const pw = M3.plain.offsetWidth;
    let n = 4; M3.ciph.textContent = cipherText(1, n);
    while (n < 40 && M3.ciph.offsetWidth < pw) { n++; M3.ciph.textContent = cipherText(1, n); }
    M.ciN = n;
    set(M3.box, { width: Math.max(pw, M3.ciph.offsetWidth) + "px" });
    M.ciW = M3.pill.offsetWidth;
    for (const tt of [0.5, 2.2, 3.6, 4.6, 5.5, 6.6, 8.7, 9.8, 11.5, 12.6, 13.4, 15.5, 16.4, 17.6, 20.3, 21.9, 22.6, 26.9, 27.3, 28.9, 29.5, 30.9, 31.6, 32.9, 33.8, 34.5, 36.5]) { renderAt(tt); await raf2(); }
    renderAt(0);
    await raf2();
  })();
})();

