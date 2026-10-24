// Nearclip promo — 39 s at 120 BPM (one beat = 0.5 s), 16:9 (1920×1080) or 9:16 (1080×1920, ?aspect=v).
// renderAt(t) draws the frame for time t; nothing depends on wall time. Cuts and hits sit on the beat grid shared
// with audio/synth.py (window.MUSIC). Story, in beats:
//   0–8    hook: "[Mac]에서 복사하고, [iPhone]에서 붙여넣기." — the platform names roll, then the Iris field zooms out
//          into the Mac's wallpaper
//   8–17   Mac → iPhone: copy an address in a note, it is in the iPhone's history
//   18–29  Android → Windows: "Send to my devices" on a sign-in code, Ctrl+V into the page on the PC
//   30–38  iPhone → Mac: the Paste button sends a photo, ⌘V drops it into a note
//   40–51  all four: the same history on macOS, Windows, Android and iOS, clips rippling from one to the others
//   52–68  four cards on solid colour: QR pairing · other networks · end-to-end encryption · one history
//   68–78  the icon, the name, the line
(function () {
  const { el, set, txt, sym, icon, clamp, lerp, prog, spring, E, kf, win, rect, rnd } = NC;
  const params = new URLSearchParams(location.search);
  const LANG = window.LANG || params.get("lang") || "ko";
  const V = (window.ASPECT || params.get("aspect")) === "v";
  const W = V ? 1080 : 1920, H = V ? 1920 : 1080;
  const docEl = document.documentElement;
  docEl.style.setProperty("--W", W + "px");
  docEl.style.setProperty("--H", H + "px");
  docEl.classList.toggle("v", V);
  docEl.lang = LANG;
  const BPM = 120, BT = 60 / BPM;
  const b = (n) => n * BT;
  const DURATION = b(78);
  const IRIS = "#4c5bf5", INK = "#101114", PAPER = "#f2f1ec";

  // ------------------------------------------------------------------ copy
  const COPY = {
    ko: {
      hook: V ? [[{ slot: 0 }, { text: "에서" }], [{ text: "복사하고," }], [{ slot: 1 }, { text: "에서" }], [{ text: "붙여넣기." }]]
        : [[{ slot: 0 }, { text: "에서 복사하고," }], [{ slot: 1 }, { text: "에서 붙여넣기." }]],
      d1: ["Mac에서 복사하면,", "iPhone에 바로."],
      d2: ["Android에서 보내고,", "Windows에서 바로 붙여넣기."],
      d3: ["iPhone 사진도,", "Mac에 그대로."],
      all: ["Mac · Windows · Android · iPhone", "모두 하나의 클립보드로."],
      labels: ["macOS", "Windows", "Android", "iOS"],
      m1: ["QR 한 번이면", "연결 끝."], m1s: "가까이 있는 기기는 코드만 찍으면 돼요.",
      m2: ["다른 네트워크에서도", "그대로."], m2s: "원격 연결을 켜면 집 Wi‑Fi와 LTE 사이에서도.",
      m3: ["종단 간", "암호화."], m3s: "복사한 내용은 내 기기만 읽을 수 있어요.",
      m4: ["기록은", "모든 기기에서 함께."], m4s: "검색하고, 고정하고, 다시 복사하세요.",
      tagline: "여기서 복사하고, 저기서 붙여넣기.",
      home: "집 Wi‑Fi", lte: "LTE", remote: "연결됨 · 원격", joined: "연결되었습니다", scan: "코드 스캔",
      query: "8시",
    },
    en: {
      hook: V ? [[{ text: "Copy on" }], [{ slot: 0 }, { text: "," }], [{ text: "paste on" }], [{ slot: 1 }, { text: "." }]]
        : [[{ text: "Copy on " }, { slot: 0 }, { text: "," }], [{ text: "paste on " }, { slot: 1 }, { text: "." }]],
      d1: ["Copy on your Mac,", "it's on your iPhone."],
      d2: ["Send from Android,", "paste on Windows."],
      d3: ["Photos from your iPhone,", "straight to your Mac."],
      all: ["Mac · Windows · Android · iPhone", "One clipboard for all of them."],
      labels: ["macOS", "Windows", "Android", "iOS"],
      m1: ["One scan,", "you're connected."], m1s: "Nearby devices pair with a QR code.",
      m2: ["Even on", "another network."], m2s: "Turn on Remote connection: home Wi‑Fi to LTE.",
      m3: ["End-to-end", "encrypted."], m3s: "Only your devices can read what you copy.",
      m4: ["One history,", "every device."], m4s: "Search it, pin it, copy it again.",
      tagline: "Copy here. Paste there.",
      home: "Home Wi‑Fi", lte: "LTE", remote: "Connected · Remote", joined: "You're connected", scan: "Scan code",
      query: "8 PM",
    },
  };
  const C = COPY[LANG] || COPY.en;
  const PLATS = ["Mac", "Windows", "Android", "iPhone"];

  // Nearclip's own strings (Android strings.xml, apple/tools/ko.json, Resources.resw).
  const UIT = {
    ko: { search: "기록 검색", filters: ["전체", "텍스트", "링크", "이미지", "고정됨"], today: "오늘", sendClipboard: "클립보드 보내기", paste: "붙여넣기",
      connected: (n) => "기기 " + n + "대에 연결됨", connectedShort: (n) => n + "대 연결됨", copiedFrom: (x) => x + "에서 복사됨", sent: (n) => "기기 " + n + "대로 보냄",
      newImage: "클립보드에 새 이미지", tapPaste: "붙여넣기를 눌러 보내세요", idle: "복사한 내용 보내기", idleSub: "복사한 뒤 붙여넣기를 누르세요", image: "이미지" },
    en: { search: "Search history", filters: ["All", "Text", "Links", "Images", "Pinned"], today: "Today", sendClipboard: "Send clipboard", paste: "Paste",
      connected: (n) => "Connected to " + n + (n === 1 ? " device" : " devices"), connectedShort: (n) => n + " connected", copiedFrom: (x) => "Copied from " + x, sent: (n) => "Sent to " + n + (n === 1 ? " device" : " devices"),
      newImage: "New image on your clipboard", tapPaste: "Tap Paste to send it to your devices", idle: "Send what you copied", idleSub: "Copy, then tap Paste", image: "Image" },
  };
  const T = UIT[LANG] || UIT.en;
  const DEV = LANG === "ko"
    ? { name: { mac: "MacBook Pro", iphone: "iPhone", android: "Galaxy S25", win: "작업실 PC" }, self: { mac: "이 Mac", iphone: "이 iPhone", android: "이 휴대폰", win: "이 PC" },
        ago: { now: "방금", m1: "1분 전", m12: "12분 전", m40: "40분 전", h1: "1시간 전", h2: "2시간 전" } }
    : { name: { mac: "MacBook Pro", iphone: "iPhone", android: "Galaxy S25", win: "Studio PC" }, self: { mac: "This Mac", iphone: "This iPhone", android: "This phone", win: "This PC" },
        ago: { now: "Just now", m1: "1 min ago", m12: "12 min ago", m40: "40 min ago", h1: "1 hr ago", h2: "2 hr ago" } };
  const TXT = LANG === "ko"
    ? { address: "서울 성동구 연무장길 41-1", base1: "내일 10시 회의 자료 공유드립니다", base4: "택배 송장 6029 1847 3301", all1: "회의는 8시로 변경됐어요",
        noteDate: "2026년 10월 24일 오후 3:12", noteTitle: "토요일 브런치", noteLines: [["시간", "오전 11:00 · 4명"], ["장소", "성수동 브런치 카페"], ["주소", "서울 성동구 연무장길 41-1"]],
        note2Date: "2026년 10월 24일 오후 3:20", note2Title: "리스본 여행", note2Lines: [["날짜", "10월 18일 – 22일"], ["메모", "트램 28번, 알파마 골목"]],
        macClock: "10월 24일 (금) 오후 3:41", winClock: ["오후 3:41", "2026-10-24"], menus: ["파일", "편집", "포맷", "보기", "윈도우", "도움말"], notes: "메모",
        browser: { tab: "본인 확인 – ivLis", url: "ivl.is/verify", heading: "본인 확인", body: "휴대폰으로 받은 인증번호 6자리를 입력하세요.", button: "확인", done: "확인되었습니다" },
        sms: { sender: "ivLis", initial: "i", day: "오늘 오후 3:41", msgPre: "[ivLis] 로그인 인증번호는 ", code: "482913", msgPost: " 입니다.", time: "오후 3:41", field: "문자 메시지", toolbar: ["복사", "모두 선택", "내 기기로 보내기"] } }
    : { address: "41-1 Yeonmujang-gil, Seoul", base1: "Slides for tomorrow's 10 AM meeting", base4: "Tracking no. 6029 1847 3301", all1: "Meeting moved to 8 PM",
        noteDate: "October 24, 2026 at 3:12 PM", noteTitle: "Saturday brunch", noteLines: [["Time", "11:00 AM · table for 4"], ["Place", "Brunch café in Seongsu"], ["Address", "41-1 Yeonmujang-gil, Seoul"]],
        note2Date: "October 24, 2026 at 3:20 PM", note2Title: "Lisbon trip", note2Lines: [["Dates", "Oct 18 – 22"], ["Notes", "Tram 28, the Alfama lanes"]],
        macClock: "Fri Oct 24  3:41 PM", winClock: ["3:41 PM", "10/24/2026"], menus: ["File", "Edit", "Format", "View", "Window", "Help"], notes: "Notes",
        browser: { tab: "Verify it's you – ivLis", url: "ivl.is/verify", heading: "Verify it's you", body: "Enter the 6-digit code we sent to your phone.", button: "Continue", done: "You're verified" },
        sms: { sender: "ivLis", initial: "i", day: "Today 3:41 PM", msgPre: "Your ivLis sign-in code is ", code: "482913", msgPost: ".", time: "3:41 PM", field: "Text message", toolbar: ["Copy", "Select all", "Send to my devices"] } };

  // ------------------------------------------------------------------ the clips
  const PHOTO = "assets/lisbon.jpg";
  // One history shared by every device; src/ago are filled in per device (a device calls its own clips "This …").
  const CLIP = {
    address: { kind: "text", title: TXT.address, dev: "mac" },
    code: { kind: "text", title: "482913", dev: "android" },
    photo: { kind: "image", title: T.image, meta: "4032×3024 · 2.4MB", img: PHOTO, dev: "iphone" },
    all1: { kind: "text", title: TXT.all1, dev: "win" },
    all2: { kind: "link", host: "github.com", path: "/ivLis-Studio", dev: "iphone" },
    base1: { kind: "text", title: TXT.base1, dev: "win" },
    base2: { kind: "link", host: "ivl.is", path: "/notes", dev: "iphone" },
    base3: { kind: "color", color: "#4c5bf5", dev: "mac" },
    base4: { kind: "text", title: TXT.base4, dev: "android" },
  };
  // list(viewer, [[id, ago, at]]) → items for one device's UI
  function list(viewer, rows) {
    return rows.map(([id, ago, at], i) => Object.assign({}, CLIP[id], {
      id: id + "@" + i, key: id, at: at == null ? null : at, ago: DEV.ago[ago] || ago,
      src: CLIP[id].dev === viewer ? DEV.self[viewer] : DEV.name[CLIP[id].dev],
    }));
  }
  const BASE = [["base1", "m12"], ["base2", "m40"], ["base3", "h1"], ["base4", "h2"]];

  // ------------------------------------------------------------------ stage
  const stage = document.getElementById("stage");
  const AUDIO = [];
  const sfx = (name, t, extra = {}) => AUDIO.push(Object.assign({ name, t: Math.round(t * 1000) / 1000 }, extra));
  const pan = (x) => Math.max(-0.75, Math.min(0.75, (x / W) * 2 - 1)) * 0.8;
  const BLUR = [];
  const blur = (from, to, samples = 6) => BLUR.push({ from, to, samples });

  function scene(bg) {
    const root = el("div.scene", { style: { background: bg } }, stage);
    const world = el("div.world", {}, root);
    const top = el("div.layer", {}, root);
    return { root, world, top };
  }

  // A caption: lines that rise out of a mask, one after another.
  function caption(parent, lines, { cls = "", color = INK, accent = IRIS, align = V ? "center" : "center", x = W / 2, y, size, gap = 1.12, weights } = {}) {
    const box = el("div.cap" + (cls ? "." + cls : ""), { style: { left: "0px", top: y + "px", width: W + "px", textAlign: align, fontSize: size + "px", color } }, parent);
    const parts = lines.map((line, i) => {
      const mask = el("div.cap-mask", {}, box);
      const inner = el("div.cap-line", { text: line, style: { color: i === lines.length - 1 && lines.length > 1 ? accent : color, fontWeight: weights ? weights[i] : 700 } }, mask);
      if (align === "left") { set(box, { left: x + "px", width: "auto" }); }
      return { mask, inner };
    });
    return {
      box, parts,
      update(t, ats, out = Infinity, outDur = 0.35) {
        parts.forEach((p, i) => {
          const at = ats[Math.min(i, ats.length - 1)];
          const a = at == null ? 0 : E.outExpo(prog(t, at, at + 0.7));
          const o = t > out ? E.inCubic(prog(t, out, out + outDur)) : 0;
          set(p.inner, { transform: "translateY(" + ((1 - a) * 105 - o * 105).toFixed(2) + "%)", opacity: at == null || t < at ? "0" : "1" });
        });
      },
    };
  }

  // ------------------------------------------------------------------ layouts (screen pixels)
  const LY = V ? {
    cap: { y: 190, size: 74 },
    d1: { mac: [40, 440, 0.758], phone: [700, 962, 0.64] },
    d2: { pc: [30, 446, 0.78], phone: [52, 966, 0.6] },
    d3: { mac: [40, 440, 0.758], phone: [64, 1006, 0.62] },
    keys: { d1: [440, 1270], d2: [600, 1250], d3: [620, 1270] },
    hook: { size: 132, y: 0 },
    zoom: 3.6,
  } : {
    cap: { y: 76, size: 64 },
    d1: { mac: [150, 236, 0.79], phone: [1412, 288, 0.7] },
    d2: { pc: [700, 226, 0.75], phone: [214, 262, 0.74] },
    d3: { mac: [720, 236, 0.79], phone: [196, 288, 0.7] },
    keys: { d1: [671, 812], d2: [1190, 760], d3: [1240, 812] },
    hook: { size: 128, y: 0 },
    zoom: 2.4,
  };

  // ================================================================== D1: Mac → iPhone (beats 8–17)
  const S1 = scene(PAPER);
  const mac1 = NC.D.macbook(S1.world, { wallpaper: IRIS, menuApp: TXT.notes, menus: TXT.menus, clock: TXT.macClock });
  const ip1 = NC.D.iphone(S1.world, {});
  const note1 = NC.X.macNote(mac1.desk, { x: 210, y: 96, w: 820, h: 500, date: TXT.noteDate, title: TXT.noteTitle, selectLine: 2,
    lines: TXT.noteLines.map(([label, text]) => ({ label, text })) });
  const t1 = { win: b(8.35), ptr: b(8.9), dragA: b(9.6), dragB: b(10.6), cmd: b(11.05), c: b(11.3), up: b(11.7), launch: b(11.85), land: b(13.45) };
  const ios1 = NC.A.iosHome(ip1.app, { T, status: T.connected(3), statusSub: DEV.name.mac + ", " + DEV.name.android + ", " + DEV.name.win,
    devices: [{ dev: "mac", on: true }, { dev: "android", on: true }, { dev: "win", on: true }],
    items: list("iphone", [["address", "now", t1.land], ...BASE]) });
  const ptr1 = NC.X.pointer(S1.top);
  const keyCmd1 = NC.X.keycap(S1.top, { label: "⌘", sub: "command", w: 104 });
  const keyC1 = NC.X.keycap(S1.top, { label: "C", w: 92 });
  const chip1 = NC.X.chip(S1.top);
  const cap1 = caption(S1.root, C.d1, { y: LY.cap.y, size: LY.cap.size });

  // ================================================================== D2: Android → Windows (beats 18–29)
  const S2 = scene(INK);
  const pc2 = NC.D.monitor(S2.world, { wallpaper: "#2a2d3a", dark: true, clock: TXT.winClock });
  const px2 = NC.D.pixel(S2.world, { dark: true });
  const browser = NC.X.winBrowser(pc2.desk, { x: 180, y: 34, w: 920, h: 600, T: TXT.browser });
  const sms = NC.X.androidMessages(px2.app, { T: TXT.sms, dark: true });
  const andToast2 = NC.A.androidToast(px2.screen, { dark: true });
  const winToast2 = NC.A.winToast(pc2.screen, { dark: true });
  const t2 = { touch: b(19.0), down: b(19.35), select: b(19.95), tapMove: b(20.8), tap: b(21.3), launch: b(21.55), land: b(23.15), ctrl: b(24.1), v: b(24.35), up: b(24.75), paste: b(24.4), click: b(26.0), ok: b(26.2) };
  const touch2 = NC.X.touch(px2.screen, { dark: true });
  const ptr2 = NC.X.pointer(pc2.screen);
  const keyCtrl2 = NC.X.keycap(S2.top, { label: "Ctrl", w: 132 });
  const keyV2 = NC.X.keycap(S2.top, { label: "V", w: 92 });
  const chip2 = NC.X.chip(S2.top);
  const cap2 = caption(S2.root, C.d2, { y: LY.cap.y, size: LY.cap.size, color: "#ffffff", accent: "#aab3ff" });

  // ================================================================== D3: iPhone → Mac (beats 30–38)
  const S3 = scene(PAPER);
  const mac3 = NC.D.macbook(S3.world, { wallpaper: INK, dark: true, menuApp: TXT.notes, menus: TXT.menus, clock: TXT.macClock });
  const ip3 = NC.D.iphone(S3.world, {});
  const note3 = NC.X.macNote(mac3.desk, { x: 150, y: 70, w: 760, h: 600, date: TXT.note2Date, title: TXT.note2Title,
    lines: [...TXT.note2Lines.map(([label, text]) => ({ label, text })), { label: "", img: PHOTO }] });
  const t3 = { fresh: b(30.6), touch: b(31.1), tap: b(31.55), sent: b(31.8), launch: b(32.0), land: b(33.6), cmd: b(34.5), v: b(34.75), up: b(35.15), drop: b(34.8) };
  const ios3 = NC.A.iosHome(ip3.app, { T, status: T.connected(3), statusSub: DEV.name.mac + ", " + DEV.name.android + ", " + DEV.name.win,
    devices: [{ dev: "mac", on: true }, { dev: "android", on: true }, { dev: "win", on: true }],
    items: list("iphone", [["photo", "now", t3.sent], ["code", "now"], ["address", "m1"], ...BASE]) });
  const macToast3 = NC.A.macToast(mac3.screen, { dark: true });
  const touch3 = NC.X.touch(ip3.screen, {});
  const keyCmd3 = NC.X.keycap(S3.top, { label: "⌘", sub: "command", w: 104 });
  const keyV3 = NC.X.keycap(S3.top, { label: "V", w: 92 });
  const chip3 = NC.X.chip(S3.top);
  const cap3 = caption(S3.root, C.d3, { y: LY.cap.y, size: LY.cap.size });

  // ================================================================== hook (beats 0–7, over the zoomed Mac wallpaper)
  const SH = el("div.layer.hook", {}, stage);
  const hookBox = el("div.hook-box", { style: { fontSize: LY.hook.size + "px" } }, SH);
  const slots = [];
  const hookLines = C.hook.map((parts) => {
    const mask = el("div.hook-mask", {}, hookBox);
    const line = el("div.hook-line", {}, mask);
    for (const p of parts) {
      if (p.text) el("span.hook-text", { text: p.text }, line);
      else {
        const pill = el("span.hook-pill", {}, line);
        const words = PLATS.map((w) => el("span.hook-word", { text: w }, pill));
        slots[p.slot] = { pill, words, widths: [] };
      }
    }
    return { mask, line };
  });
  // Which platform each slot shows, by beat.
  const SEQ = [[0, [0, 3]], [2, [1, 2]], [3, [2, 0]], [4, [3, 1]], [5, [0, 3]]];

  NC.SCENES = { S1, S2, S3, SH, mac1, ip1, note1, ios1, ptr1, keyCmd1, keyC1, chip1, cap1, t1,
    pc2, px2, browser, sms, andToast2, winToast2, touch2, ptr2, keyCtrl2, keyV2, chip2, cap2, t2,
    mac3, ip3, note3, ios3, macToast3, touch3, keyCmd3, keyV3, chip3, cap3, t3,
    hookLines, slots, SEQ, scene, caption, list, LY, C, T, DEV, TXT, CLIP, BASE, PLATS, b, W, H, V, LANG, IRIS, INK, PAPER, sfx, pan, blur, AUDIO, BLUR, DURATION };
})();

