#!/usr/bin/env python3
"""Local demo / acceptance harness for the macOS app.

Starts an isolated instance of the built Nearclip.app (own state dir, port 45900 and defaults suite),
pairs CLI peers that impersonate an iPhone, a Windows PC and an Android phone through the app's
real QR ticket, and sends realistic clips. Peers stay online until you press Ctrl-C.

  python3 apple/tools/demo.py [--show panel|add|settings:devices|...] [--no-clips]
Commands on stdin while running:  text <peer> <text> | image <peer> <path> | quit
"""
import argparse, json, os, shlex, shutil, signal, subprocess, sys, threading, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP = os.path.join(ROOT, "apple/build/dd/Build/Products/Debug/Nearclip.app/Contents/MacOS/Nearclip")
CLI = os.path.join(ROOT, "apple/NearclipKit/.build/release/nearclip-cli")
BASE = "/tmp/nearclip-demo"

class Peer:
    def __init__(self, name, platform):
        self.name, self.platform = name, platform
        self.state = os.path.join(BASE, platform)
        os.makedirs(self.state, exist_ok=True)
        self.events, self.cond = [], threading.Condition()
        self.proc = subprocess.Popen([CLI, "--state", self.state, "--name", name, "--port", "0", "--platform", platform],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()
        self.ready = self.wait(lambda e: e.get("ev") == "ready")

    def _read(self):
        for line in self.proc.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            with self.cond:
                self.events.append(ev)
                self.cond.notify_all()
            if ev.get("ev") in ("paired", "peer_up", "peer_down", "pair_failed", "left"):
                print(f"  [{self.name}] {ev}", flush=True)
            elif ev.get("ev") == "clip":
                what = ev.get("text") if ev.get("kind") == "text" else f"image {ev.get('size')} bytes"
                print(f"  [{self.name}] got clip live={ev.get('live')}: {what!r}", flush=True)

    def wait(self, pred, timeout=30):
        end = time.time() + timeout
        with self.cond:
            while True:
                for e in self.events:
                    if pred(e):
                        return e
                if time.time() > end:
                    raise TimeoutError(self.name)
                self.cond.wait(0.2)

    def send(self, **cmd):
        self.proc.stdin.write(json.dumps(cmd, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

def local(uri):
    p = urlsplit(uri)
    q = [(k, "127.0.0.1" if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    return urlunsplit((p.scheme, p.netloc, p.path, urlencode(q), ""))

def start_app(show, extra=None):
    env = dict(os.environ, NC_STATE_DIR=os.path.join(BASE, "mac"), NC_PORT="45900",
               NC_DEFAULTS_SUITE="studio.ivlis.nearclip.demo", NC_TICKET_FILE=os.path.join(BASE, "ticket.txt"),
               NC_PASTEBOARD="studio.ivlis.nearclip.demo-pasteboard")
    env.update(extra or {})
    if show:
        env["NC_SHOW"] = show
    log = open(os.path.join(BASE, "app.log"), "a")
    return subprocess.Popen([APP], env=env, stdout=log, stderr=log)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--show", default="add")
    ap.add_argument("--fresh", action="store_true", help="wipe previous demo state")
    ap.add_argument("--no-clips", action="store_true")
    args = ap.parse_args()
    if args.fresh and os.path.exists(BASE):
        shutil.rmtree(BASE)
    os.makedirs(BASE, exist_ok=True)
    fresh = not os.path.exists(os.path.join(BASE, "paired"))
    ticket = os.path.join(BASE, "ticket.txt")
    if os.path.exists(ticket):
        os.remove(ticket)
    app = start_app("add" if fresh else args.show)
    peers = [Peer("Junseo's iPhone", "ios"), Peer("DESKTOP-STUDIO", "win"), Peer("Pixel 9 Pro", "android")]
    if fresh:
        last = None
        for p in peers:
            end = time.time() + 30
            while time.time() < end:
                uri = open(ticket).read().strip() if os.path.exists(ticket) else None
                if uri and uri != last:
                    break
                time.sleep(0.2)
            else:
                raise SystemExit("no ticket from the app")
            last = uri
            p.send(cmd="pair_qr", uri=local(uri))
            p.wait(lambda e: e.get("ev") == "paired")
            time.sleep(0.6)
        open(os.path.join(BASE, "paired"), "w").write("1")
    for p in peers:
        p.wait(lambda e: e.get("ev") == "peer_up", timeout=60)
    print("all peers connected", flush=True)
    if fresh and not args.no_clips:
        iphone, pc, pixel = peers
        img = os.path.join(BASE, "photo.png")
        if not os.path.exists(img):
            srcs = [f for f in ["/System/Library/Desktop Pictures/.thumbnails/Sonoma.heic", "/Library/User Pictures/Nature/Earth.heic"] if os.path.exists(f)]
            pics = srcs or [os.path.join(dp, f) for dp, _, fs in os.walk("/Library/User Pictures") for f in fs if f.lower().endswith((".heic", ".tif", ".jpg", ".png"))][:1]
            subprocess.run(["sips", "-s", "format", "png", "-Z", "900", pics[0], "--out", img], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        script = [
            (pixel, "image", img),
            (pc, "text", "func greet(_ name: String) -> String {\n    let message = \"Hello, \\(name)!\"\n    return message\n}"),
            (pixel, "text", "#4C5BF5"),
            (pc, "text", "ssh deploy@192.168.0.40 -p 2222"),
            (iphone, "text", "회의 끝나고 7시에 강남역 2번 출구에서 만나요 🙌"),
            (iphone, "text", "https://github.com/ivLis-Studio/nearclip/releases"),
        ]
        for peer, kind, value in script:
            if kind == "image":
                peer.send(cmd="send_image", path=value, mime="image/png")
            else:
                peer.send(cmd="send_text", text=value)
            time.sleep(1.2)
        print("clips sent", flush=True)
    print("demo running — commands: text <ios|win|android> <text> | image <peer> <path> | restart <show> | quit", flush=True)
    by = {p.platform: p for p in peers}
    for line in sys.stdin:
        parts = line.strip().split(" ", 2)
        if not parts or not parts[0]:
            continue
        if parts[0] == "quit":
            break
        if parts[0] == "text" and len(parts) == 3:
            by[parts[1]].send(cmd="send_text", text=parts[2])
        elif parts[0] == "image" and len(parts) == 3:
            by[parts[1]].send(cmd="send_image", path=parts[2], mime="image/png")
        elif parts[0] == "restart":
            app.terminate(); app.wait(5)
            show, extra = (parts[1] if len(parts) > 1 else None), {}
            for kv in (parts[2].split() if len(parts) > 2 else []):
                k, _, v = kv.partition("=")
                extra[k] = v
            app = start_app(show, extra)
        print("ok", flush=True)
    for p in peers:
        p.send(cmd="quit")
    app.terminate()

if __name__ == "__main__":
    main()

