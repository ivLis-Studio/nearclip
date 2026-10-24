// Device frames and OS chrome, drawn flat: MacBook, Windows monitor, Pixel, iPhone. Screens are laid out in the
// device's own logical units (points / dp / px) and the whole device is placed with one transform.
(function () {
  const { el, set, sym, icon } = NC;
  const D = (NC.D = {});

  function placer(root) {
    return (x, y, s = 1, extra = "") => set(root, { transform: "translate(" + x + "px," + y + "px) scale(" + s + ")" + extra });
  }

  // ------------------------------------------------------------------ MacBook
  // screen 1280×800 pt. Frame units = screen points.
  D.macbook = function (parent, { wallpaper = "#4c5bf5", dark = false, menuApp = "메모", menus = [], clock = "" } = {}) {
    const SW = 1280, SH = 800, B = 20;
    const root = el("div.dev.dev-mac", {}, parent);
    const lid = el("div.mac-lid", { style: { width: SW + 2 * B + "px", height: SH + 2 * B + 6 + "px" } }, root);
    const screen = el("div.mac-screen", { style: { left: B + "px", top: B + "px", width: SW + "px", height: SH + "px", background: wallpaper } }, lid);
    const base = el("div.mac-base", { style: { width: SW + 2 * B + 150 + "px", left: -75 + "px", top: SH + 2 * B + 4 + "px" } }, root);
    el("div.mac-lip", {}, base);
    const bar = el("div.mac-menubar" + (dark ? ".dark" : ""), {}, screen);
    const left = el("div.mac-menus", {}, bar);
    el("b", { text: menuApp }, left);
    for (const m of menus) el("span", { text: m }, left);
    const right = el("div.mac-status", {}, bar);
    const nc = el("span.mac-nc", {}, right);
    icon("brand", "mono", 17, nc);
    sym("wifi", 15, "currentColor", right);
    sym("battery.100percent", 22, "currentColor", right);
    sym("switch.2", 15, "currentColor", right);
    el("span.mac-clock", { text: clock }, right);
    const desk = el("div.mac-desk", {}, screen);
    return { root, screen, desk, bar, nc, place: placer(root), W: SW + 2 * B, H: SH + 2 * B + 30, SW, SH, B };
  };

  // ------------------------------------------------------------------ Windows monitor (screen 1280×720 px)
  D.monitor = function (parent, { wallpaper = "#1b1d24", dark = true, clock = ["오후 3:41", "2026-10-24"] } = {}) {
    const SW = 1280, SH = 720, B = 14;
    const root = el("div.dev.dev-pc", {}, parent);
    const panel = el("div.pc-panel", { style: { width: SW + 2 * B + "px", height: SH + 2 * B + 8 + "px" } }, root);
    const screen = el("div.pc-screen", { style: { left: B + "px", top: B + "px", width: SW + "px", height: SH + "px", background: wallpaper } }, panel);
    el("div.pc-neck", { style: { left: (SW + 2 * B) / 2 - 70 + "px", top: SH + 2 * B + 8 + "px" } }, root);
    el("div.pc-foot", { style: { left: (SW + 2 * B) / 2 - 190 + "px", top: SH + 2 * B + 8 + 120 + "px" } }, root);
    const desk = el("div.pc-desk", {}, screen);
    const bar = el("div.win-taskbar" + (dark ? ".dark" : ""), {}, screen);
    const mid = el("div.win-tb-mid", {}, bar);
    const start = el("span.win-tb-btn.win-start", {}, mid);
    for (let i = 0; i < 4; i++) el("i", {}, start);
    const search = el("span.win-tb-btn", {}, mid);
    icon("f", "search", 22, search);
    const files = el("span.win-tb-btn.win-files", {}, mid);
    icon("f", "folder_filled", 24, files);
    const web = el("span.win-tb-btn.win-web", {}, mid);
    icon("f", "globe", 22, web);
    el("span.win-tb-dot", {}, web);
    const tray = el("div.win-tray", {}, bar);
    const nc = el("span.win-tray-nc", {}, tray);
    icon("brand", "mono", 18, nc);
    icon("f", "wifi_1", 18, tray);
    icon("f", "speaker_2", 18, tray);
    icon("f", "battery_10", 18, tray);
    const time = el("span.win-clock", {}, tray);
    el("span", { text: clock[0] }, time);
    el("span", { text: clock[1] }, time);
    return { root, screen, desk, bar, nc, place: placer(root), W: SW + 2 * B, H: SH + 2 * B + 150, SW, SH, B };
  };

  // ------------------------------------------------------------------ phones
  function statusIcons(parent, kind, dark) {
    const row = el("div." + kind + "-sbi", {}, parent);
    if (kind === "ios") {
      sym("cellularbars", 18, "currentColor", row);
      sym("wifi", 17, "currentColor", row);
      sym("battery.100percent", 27, "currentColor", row);
    } else {
      icon("m", "wifi", 17, row);
      el("i.and-signal", {}, row, '<svg viewBox="0 0 24 24"><path d="M3 21 L21 21 L21 3 Z" fill="currentColor"/></svg>');
      el("i.and-battery", {}, row, '<svg viewBox="0 0 24 24"><rect x="7" y="3" width="10" height="19" rx="2" fill="currentColor"/><rect x="10" y="1.5" width="4" height="2" rx="0.6" fill="currentColor"/></svg>');
    }
    return row;
  }

  // Pixel-like phone: screen 412×915 dp.
  D.pixel = function (parent, { dark = false, clock = "9:41", bg } = {}) {
    const SW = 412, SH = 915, B = 11;
    const root = el("div.dev.dev-pixel", {}, parent);
    const body = el("div.pixel-body", { style: { width: SW + 2 * B + "px", height: SH + 2 * B + "px" } }, root);
    const screen = el("div.phone-screen.pixel-screen" + (dark ? ".dark" : ""), { style: { left: B + "px", top: B + "px", width: SW + "px", height: SH + "px", background: bg || (dark ? "#121316" : "#f7f8fc") } }, body);
    const app = el("div.phone-app", {}, screen);
    const sb = el("div.and-status", {}, screen);
    el("span", { text: clock }, sb);
    statusIcons(sb, "and", dark);
    el("div.pixel-cam", {}, screen);
    el("div.and-gesture", {}, screen);
    el("div.pixel-btn", { style: { top: "220px" } }, root);
    el("div.pixel-btn.small", { style: { top: "340px" } }, root);
    return { root, screen, app, status: sb, place: placer(root), W: SW + 2 * B, H: SH + 2 * B, SW, SH, B };
  };

  // iPhone: screen 402×874 pt.
  D.iphone = function (parent, { dark = false, clock = "9:41", bg } = {}) {
    const SW = 402, SH = 874, B = 12;
    const root = el("div.dev.dev-iphone", {}, parent);
    const body = el("div.iphone-body", { style: { width: SW + 2 * B + "px", height: SH + 2 * B + "px" } }, root);
    const screen = el("div.phone-screen.iphone-screen" + (dark ? ".dark" : ""), { style: { left: B + "px", top: B + "px", width: SW + "px", height: SH + "px", background: bg || (dark ? "#000" : "#f2f2f7") } }, body);
    const app = el("div.phone-app", {}, screen);
    const sb = el("div.ios-status", {}, screen);
    el("span", { text: clock }, sb);
    statusIcons(sb, "ios", dark);
    el("div.iphone-island", {}, screen);
    el("div.ios-homebar", {}, screen);
    el("div.iphone-btn", { style: { top: "170px", height: "34px" } }, root);
    el("div.iphone-btn", { style: { top: "230px" } }, root);
    el("div.iphone-btn", { style: { top: "300px" } }, root);
    el("div.iphone-btn.right", { style: { top: "250px", height: "110px" } }, root);
    return { root, screen, app, status: sb, place: placer(root), W: SW + 2 * B, H: SH + 2 * B, SW, SH, B };
  };
})();

