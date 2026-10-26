// Nearclip promo — 39 s at 120 BPM (one beat = 0.5 s), 16:9 (1920×1080) or 9:16 (1080×1920, ?aspect=v).
// renderAt(t) draws the frame for time t; nothing depends on wall time. Cuts and hits sit on the beat grid shared
// with audio/synth.py (window.MUSIC). Every demo crosses ecosystems: the pairs Apple, Microsoft and Google already
// connect among their own devices are left out. Story, in beats:
//   0–8    hook: "[Mac]에서 복사하고, [Windows]에서 붙여넣기." — the names roll through mixed pairs, then the camera
//          pulls back out of the Mac's wallpaper
//   8–17   Mac → Windows: copy an address in a note on the Mac, Ctrl+V into a map search on the PC
//   18–29  Android → Mac: a sign-in code texted to the phone (screen off, nobody touches it) comes to the Mac by itself;
//          the capsule asks "Copy it?", Copy, ⌘V into the sign-in page
//   30–39  iPhone → Windows: the Paste button sends a photo, Ctrl+V drops it into a chat on the PC
//   40–51  all four: the same history on macOS, Windows, Android and iOS, clips rippling from one to the others
//   52–67  four cards on solid colour: QR pairing · other networks · end-to-end encryption · one history
//   67–78  the icon, the name, the line
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
      d1: ["Mac에서 복사하면,", "Windows PC에 바로."],
      d2: ["문자로 온 인증번호,", "Mac에서 바로 복사."],
      d3: ["iPhone 사진도,", "Windows PC에 그대로."],
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
      d1: ["Copy on your Mac,", "paste on your Windows PC."],
      d2: ["A code on your phone,", "ready on your Mac."],
      d3: ["Photos from your iPhone,", "straight to your PC."],
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
      codeArrived: (x) => x + "에서 인증번호가 도착했어요! 복사할까요?", copy: "복사", notNow: "나중에",
      newImage: "클립보드에 새 이미지", tapPaste: "붙여넣기를 눌러 보내세요", idle: "복사한 내용 보내기", idleSub: "복사한 뒤 붙여넣기를 누르세요", image: "이미지" },
    en: { search: "Search history", filters: ["All", "Text", "Links", "Images", "Pinned"], today: "Today", sendClipboard: "Send clipboard", paste: "Paste",
      connected: (n) => "Connected to " + n + (n === 1 ? " device" : " devices"), connectedShort: (n) => n + " connected", copiedFrom: (x) => "Copied from " + x, sent: (n) => "Sent to " + n + (n === 1 ? " device" : " devices"),
      codeArrived: (x) => "A verification code arrived from " + x + ". Copy it?", copy: "Copy", notNow: "Not Now",
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
        macClock: "10월 24일 (금) 오후 3:41", winClock: ["오후 3:41", "2026-10-24"], menus: ["파일", "편집", "포맷", "보기", "윈도우", "도움말"], notes: "메모",
        safariMenus: ["파일", "편집", "보기", "방문 기록", "책갈피", "윈도우", "도움말"],
        browser: { tab: "본인 확인 – ivLis", url: "ivl.is/verify", heading: "본인 확인", body: "휴대폰으로 받은 인증번호 6자리를 입력하세요.", button: "확인", done: "확인되었습니다" },
        map: { title: "지도", placeholder: "장소, 주소 검색", place: "성수동 브런치 카페", address: "서울 성동구 연무장길 41-1", directions: "길찾기", save: "저장" },
        chat: { title: "여행 준비", room: "여행 준비", members: "3명", day: "오늘", a1: "하", a2: "준", a1name: "하늘", ask: "리스본 사진 있어? 트램 나온 거!", reply: "완벽해, 고마워!", time: "오후 3:42", placeholder: "메시지 입력" },
        sms: { sender: "ivLis", initial: "i", now: "지금", lockTime: "3:41", lockDate: "10월 24일 금요일", msgPre: "[ivLis] 로그인 인증번호는 ", code: "482913", msgPost: " 입니다." } }
    : { address: "41-1 Yeonmujang-gil, Seoul", base1: "Slides for tomorrow's 10 AM meeting", base4: "Tracking no. 6029 1847 3301", all1: "Meeting moved to 8 PM",
        noteDate: "October 24, 2026 at 3:12 PM", noteTitle: "Saturday brunch", noteLines: [["Time", "11:00 AM · table for 4"], ["Place", "Brunch café in Seongsu"], ["Address", "41-1 Yeonmujang-gil, Seoul"]],
        macClock: "Fri Oct 24  3:41 PM", winClock: ["3:41 PM", "10/24/2026"], menus: ["File", "Edit", "Format", "View", "Window", "Help"], notes: "Notes",
        safariMenus: ["File", "Edit", "View", "History", "Bookmarks", "Window", "Help"],
        browser: { tab: "Verify it's you – ivLis", url: "ivl.is/verify", heading: "Verify it's you", body: "Enter the 6-digit code we sent to your phone.", button: "Continue", done: "You're verified" },
        map: { title: "Maps", placeholder: "Search places or addresses", place: "Brunch café in Seongsu", address: "41-1 Yeonmujang-gil, Seoul", directions: "Directions", save: "Save" },
        chat: { title: "Trip planning", room: "Trip planning", members: "3 people", day: "Today", a1: "S", a2: "J", a1name: "Sky", ask: "Got the Lisbon photo? The one with the tram!", reply: "Perfect, thanks!", time: "3:42 PM", placeholder: "Type a message" },
        sms: { sender: "ivLis", initial: "i", now: "now", lockTime: "3:41", lockDate: "Friday, October 24", msgPre: "Your ivLis sign-in code is ", code: "482913", msgPost: "." } };

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
  function caption(parent, lines, { cls = "", color = INK, accent = IRIS, align = "center", x = W / 2, y, size, weights } = {}) {
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

  // ------------------------------------------------------------------ layouts (screen pixels): device [x, y, scale]
  const LY = V ? {
    cap: { y: 190, size: 74 },
    d1: { mac: [40, 400, 0.758], pc: [30, 940, 0.78] },
    d2: { mac: [40, 430, 0.758], phone: [40, 900, 0.7] },
    d3: { pc: [30, 420, 0.78], phone: [50, 960, 0.66] },
    keys: { d1mac: [540, 902], d1pc: [540, 1416], d2: [706, 1186], d3: [690, 1190] },
    hook: { size: 132, y: 0 },
    zoom: 3.6,
  } : {
    cap: { y: 76, size: 64 },
    d1: { mac: [36, 300, 0.74], pc: [900, 262, 0.75] },
    d2: { phone: [214, 262, 0.74], mac: [640, 250, 0.84] },
    d3: { phone: [196, 288, 0.7], pc: [700, 226, 0.75] },
    keys: { d1mac: [512, 798], d1pc: [1390, 812], d2: [1194, 846], d3: [1190, 772] },
    hook: { size: 128, y: 0 },
    zoom: 2.6,
  };
  const PCWALL = "#2a2d3a";

  // ================================================================== D1: Mac → Windows (beats 8–17)
  const S1 = scene(PAPER);
  const t1 = { win: b(7.9), ptr: b(8.4), dragA: b(9.0), dragB: b(10.0), cmd: b(10.4), c: b(10.66), up: b(11.1), launch: b(11.24), land: b(12.84),
    ctrl: b(13.56), v: b(13.8), vup: b(14.24), paste: b(13.84), pin: b(14.44) };
  const pc1 = NC.D.monitor(S1.world, { wallpaper: PCWALL, dark: true, clock: TXT.winClock });
  const mac1 = NC.D.macbook(S1.world, { wallpaper: IRIS, menuApp: TXT.notes, menus: TXT.menus, clock: TXT.macClock });
  const note1 = NC.X.macNote(mac1.desk, { x: 210, y: 96, w: 820, h: 500, date: TXT.noteDate, title: TXT.noteTitle, selectLine: 2,
    lines: TXT.noteLines.map(([label, text]) => ({ label, text })) });
  const map1 = NC.X.winMap(pc1.desk, V ? { x: 120, y: 172, w: 1040, h: 480, T: TXT.map } : { x: 160, y: 40, w: 1080, h: 600, T: TXT.map });
  const winToast1 = NC.A.winToast(pc1.screen, { dark: true });
  const ptr1 = NC.X.pointer(S1.top);
  const keyCmd1 = NC.X.keycap(S1.top, { label: "⌘", sub: "command", w: 104 });
  const keyC1 = NC.X.keycap(S1.top, { label: "C", w: 92 });
  const keyCtrl1 = NC.X.keycap(S1.top, { label: "Ctrl", w: 132 });
  const keyV1 = NC.X.keycap(S1.top, { label: "V", w: 92 });
  const chip1 = NC.X.chip(S1.top);
  const cap1 = caption(S1.root, C.d1, { y: LY.cap.y, size: LY.cap.size });

  // ================================================================== D2: Android → Mac (beats 18–29)
  const S2 = scene(INK);
  // sms: the message wakes the phone · detect: Nearclip finds the code in the notification · launch/land: the code
  // travels by itself · copy: Copy in the capsule · cmd/v/paste/up: ⌘V into the page · click/ok: Continue, verified
  const t2 = { sms: b(18.5), detect: b(19.4), launch: b(20.6), land: b(22.2), copy: b(24.2), cmd: b(25.0), v: b(25.25), up: b(25.65), paste: b(25.3), click: b(25.96), ok: b(26.2) };
  const mac2 = NC.D.macbook(S2.world, { wallpaper: IRIS, menuApp: "Safari", menus: TXT.safariMenus, clock: TXT.macClock });
  const px2 = NC.D.pixel(S2.world, { dark: true, clock: "" });
  const browser2 = NC.X.macBrowser(mac2.desk, V ? { x: 140, y: 30, w: 1000, h: 580, T: TXT.browser } : { x: 170, y: 40, w: 940, h: 600, T: TXT.browser });
  const lock2 = NC.X.androidLock(px2.app, { T: TXT.sms });
  const macCode2 = NC.A.macCodeToast(mac2.screen, { dark: true, title: T.codeArrived(DEV.name.android), copied: T.copiedFrom(DEV.name.android),
    code: TXT.sms.code, copy: T.copy, notNow: T.notNow, dev: "android" });
  const ptr2 = NC.X.pointer(mac2.screen);
  const keyCmd2 = NC.X.keycap(S2.top, { label: "⌘", sub: "command", w: 104 });
  const keyV2 = NC.X.keycap(S2.top, { label: "V", w: 92 });
  const chip2 = NC.X.chip(S2.top);
  const cap2 = caption(S2.root, C.d2, { y: LY.cap.y, size: LY.cap.size, color: "#ffffff", accent: "#aab3ff" });

  // ================================================================== D3: iPhone → Windows (beats 30–39)
  const S3 = scene(PAPER);
  const t3 = { fresh: b(30.6), touch: b(31.1), tap: b(31.55), sent: b(31.8), launch: b(32.0), land: b(33.6), ctrl: b(34.5), v: b(34.75), up: b(35.15), paste: b(34.8), reply: b(36.6) };
  const pc3 = NC.D.monitor(S3.world, { wallpaper: PCWALL, dark: true, clock: TXT.winClock });
  const ip3 = NC.D.iphone(S3.world, {});
  const chat3 = NC.X.winChat(pc3.desk, { x: 160, y: 30, w: 760, h: 610, T: TXT.chat, photo: PHOTO });
  const ios3 = NC.A.iosHome(ip3.app, { T, status: T.connected(3), statusSub: DEV.name.mac + ", " + DEV.name.android + ", " + DEV.name.win,
    devices: [{ dev: "mac", on: true }, { dev: "android", on: true }, { dev: "win", on: true }],
    items: list("iphone", [["photo", "now", t3.sent], ["code", "now"], ["address", "m1"], ...BASE]) });
  const winToast3 = NC.A.winToast(pc3.screen, { dark: true });
  const touch3 = NC.X.touch(ip3.screen, {});
  const keyCtrl3 = NC.X.keycap(S3.top, { label: "Ctrl", w: 132 });
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
        slots[p.slot] = { pill, words: [], widths: [] };
      }
    }
    return { mask, line };
  });
  // Which platforms the two slots show, by beat: always one Apple and one non-Apple device or two different worlds,
  // never a pair that already shares a clipboard.
  const SEQ = [[0, [0, 1]], [2, [2, 0]], [3, [3, 2]], [4, [1, 3]], [5, [0, 1]]];

  NC.SCENES = { S1, S2, S3, SH, pc1, mac1, note1, map1, winToast1, ptr1, keyCmd1, keyC1, keyCtrl1, keyV1, chip1, cap1, t1,
    mac2, px2, browser2, lock2, macCode2, ptr2, keyCmd2, keyV2, chip2, cap2, t2,
    pc3, ip3, chat3, ios3, winToast3, touch3, keyCtrl3, keyV3, chip3, cap3, t3,
    hookLines, slots, SEQ, scene, caption, list, LY, C, T, DEV, TXT, CLIP, BASE, PLATS, b, W, H, V, LANG, IRIS, INK, PAPER, sfx, pan, blur, AUDIO, BLUR, DURATION };
})();

