#!/usr/bin/env python3
"""Mac App Store screenshots of the menu bar app, with clean demo devices and clips.

Runs an isolated copy of the app (its own state directory, port 45900, defaults suite and a private pasteboard, so the
Nearclip you use is untouched), names it "MacBook Pro", pairs three CLI peers that stand in for an iPhone, a Windows PC
and a Galaxy phone, sends a short history, then opens each surface and captures its window (no shadow, 2x):
panel.png (the history panel under the menu bar) and devices.png (Settings › Devices). promo/appstore.sh frames them.

  python3 apple/tools/appstore_mac_shots.py --lang en --out promo/out/appstore/raw/mac-en

Needs the Debug build at apple/build/dd (xcodebuild -scheme Nearclip -derivedDataPath apple/build/dd build) and
Screen Recording permission for the terminal.
"""
import argparse, json, os, shlex, subprocess, sys, tempfile, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)
from tools.interop.run import Peer, local_uri

APP = os.path.join(ROOT, "apple/build/dd/Build/Products/Debug/Nearclip.app/Contents/MacOS/Nearclip")
CLI = shlex.quote(os.path.join(ROOT, "apple/NearclipKit/.build/release/nearclip-cli"))
PHOTO = os.path.join(ROOT, "promo/assets/lisbon.jpg")
COPY = {
    "en": {"pc": "Studio PC", "clips": [
        ("galaxy", "image", None),
        ("pc", "text", "Slides for tomorrow's 10 AM meeting"),
        ("iphone", "text", "https://github.com/ivLis-Studio/nearclip"),
        ("galaxy", "text", "482913"),
        ("iphone", "text", "41-1 Yeonmujang-gil, Seongdong-gu, Seoul"),
        ("pc", "text", "#4C5BF5"),
        ("iphone", "text", "Meeting moved to 8 PM"),
    ]},
    "ko": {"pc": "작업실 PC", "clips": [
        ("galaxy", "image", None),
        ("pc", "text", "내일 10시 회의 자료 공유드립니다"),
        ("iphone", "text", "https://github.com/ivLis-Studio/nearclip"),
        ("galaxy", "text", "482913"),
        ("iphone", "text", "서울 성동구 연무장길 41-1"),
        ("pc", "text", "#4C5BF5"),
        ("iphone", "text", "회의 8시로 변경됐어요"),
    ]},
}


class App:
    def __init__(self, base, lang):
        self.base, self.lang, self.proc = base, lang, None
        self.state = os.path.join(base, "mac")
        self.ticket = os.path.join(base, "ticket.txt")

    def start(self, show):
        env = dict(os.environ, NC_STATE_DIR=self.state, NC_PORT="45900", NC_SHOW=show, NC_TICKET_FILE=self.ticket,
                   NC_DEFAULTS_SUITE="studio.ivlis.nearclip.appstore-" + self.lang,
                   NC_PASTEBOARD="studio.ivlis.nearclip.appstore-pasteboard")
        args = [APP, "-AppleLanguages", f"({self.lang})", "-AppleLocale", "ko_KR" if self.lang == "ko" else "en_US"]
        self.proc = subprocess.Popen(args, env=env, stdout=open(os.path.join(self.base, "app.log"), "a"), stderr=subprocess.STDOUT)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(10)


def wait_file(path, timeout=30, other_than=None):
    end = time.time() + timeout
    while time.time() < end:
        if os.path.exists(path):
            s = open(path).read().strip()
            if s and s != other_than:
                return s
        time.sleep(0.2)
    raise SystemExit(f"no {path}")


def capture(pid, out, winlist, pick):
    time.sleep(2.5)
    rows = []
    for line in subprocess.run([winlist, str(pid)], capture_output=True, text=True).stdout.splitlines():
        parts = line.split(" ", 6)
        if len(parts) >= 6:
            rows.append((int(parts[0]), int(parts[1]), int(parts[4]), int(parts[5]), parts[6] if len(parts) > 6 else ""))
    cands = [r for r in rows if pick(r)]
    if not cands:
        raise SystemExit(f"no window for {out}: {rows}")
    wid = max(cands, key=lambda r: r[2] * r[3])[0]
    subprocess.run(["screencapture", "-o", "-x", "-l", str(wid), out], check=True)
    print("captured", out, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", choices=COPY, default="en")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    copy, out = COPY[args.lang], os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    base = tempfile.mkdtemp(prefix="nearclip-appstore-mac-")
    winlist = os.path.join(base, "winlist")
    subprocess.run(["swiftc", "-O", "-o", winlist, os.path.join(ROOT, "apple/tools/winlist.swift")], check=True)
    subprocess.run(["defaults", "delete", "studio.ivlis.nearclip.appstore-" + args.lang], capture_output=True)

    app = App(base, args.lang)
    app.start("add")
    wait_file(os.path.join(app.state, "state.json"))
    time.sleep(1)
    app.stop()
    # This Mac is called "MacBook Pro" in the pictures, not by the name of the Mac that took them.
    st = json.load(open(os.path.join(app.state, "state.json")))
    st["deviceName"] = "MacBook Pro"
    json.dump(st, open(os.path.join(app.state, "state.json"), "w"))
    if os.path.exists(app.ticket):
        os.remove(app.ticket)
    app.start("add")

    peers = {
        "iphone": Peer("swift", CLI + " --platform ios", "iPhone", state=os.path.join(base, "iphone")),
        "pc": Peer("swift", CLI + " --platform win", copy["pc"], state=os.path.join(base, "pc")),
        "galaxy": Peer("swift", CLI + " --platform android", "Galaxy S25", state=os.path.join(base, "galaxy")),
    }
    try:
        last = None
        for k in ("iphone", "pc", "galaxy"):
            uri = wait_file(app.ticket, other_than=last)
            last = uri
            peers[k].send(cmd="pair_qr", uri=local_uri(uri))
            peers[k].expect("paired", lambda e: e.get("ev") == "paired", 30)
            time.sleep(0.8)
        time.sleep(2)
        for who, kind, value in copy["clips"]:
            if kind == "image":
                peers[who].send(cmd="send_image", path=PHOTO, mime="image/jpeg")
            else:
                peers[who].send(cmd="send_text", text=value)
            time.sleep(1.2)
        time.sleep(2)
        for show, name, pick in [
            ("panel", "panel.png", lambda r: r[2] < 700 and r[3] > 300),
            ("settings:devices", "devices.png", lambda r: r[1] == 0 and r[2] > 500),
        ]:
            app.stop()
            app.start(show)
            for p in peers.values():
                p.mark()
            for p in peers.values():
                try:
                    p.expect("reconnect", lambda e: e.get("ev") == "peer_up", 30)
                except AssertionError:
                    pass
            capture(app.proc.pid, os.path.join(out, name), winlist, pick)
    finally:
        app.stop()
        for p in peers.values():
            p.quit()
        subprocess.run(["defaults", "delete", "studio.ivlis.nearclip.appstore-" + args.lang], capture_output=True)
    print("shots", out, sorted(os.listdir(out)), flush=True)


if __name__ == "__main__":
    main()

