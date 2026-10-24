#!/usr/bin/env python3
"""Remote-connection demo / acceptance for the macOS app (PROTOCOL.md section 10).

Starts a throwaway Tailscale control server (tailnet/out/nctestcontrol), an isolated Nearclip.app with remote
connection on, and a CLI peer ("Galaxy S25") that pairs on the LAN and then comes back through the tailnet only
(--remote-only), so the app shows it as "Connected - Remote".

  python3 apple/tools/remote_demo.py [--show settings:general]
stdin while running:  text <text> | restart <show> | quit
"""
import argparse, json, os, subprocess, sys, tempfile, threading, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP = os.path.join(ROOT, "apple/build/dd/Build/Products/Debug/Nearclip.app/Contents/MacOS/Nearclip")
CLI = os.path.join(ROOT, "apple/NearclipKit/.build/release/nearclip-cli")
CONTROL = os.path.join(ROOT, "tailnet/out/nctestcontrol")
SUITE = "studio.ivlis.nearclip.remote-demo"

class Peer:
    def __init__(self, base, url, extra=()):
        self.state = os.path.join(base, "s25")
        os.makedirs(self.state, exist_ok=True)
        self.events, self.cond = [], threading.Condition()
        args = [CLI, "--state", self.state, "--name", "Galaxy S25", "--platform", "android", "--port", "0",
                "--tailnet", os.path.join(self.state, "tailnet"), "--tailnet-control", url, *extra]
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            with self.cond:
                self.events.append(ev)
                self.cond.notify_all()
            if ev.get("ev") in ("paired", "peer_up", "peer_down", "pair_failed", "tailnet", "clip"):
                print("  [Galaxy S25]", ev, flush=True)

    def wait(self, pred, timeout=60):
        end = time.time() + timeout
        with self.cond:
            while True:
                for e in self.events:
                    if pred(e):
                        return e
                if time.time() > end:
                    raise TimeoutError("Galaxy S25")
                self.cond.wait(0.2)

    def send(self, **cmd):
        self.proc.stdin.write(json.dumps(cmd, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def quit(self):
        try:
            self.send(cmd="quit")
            self.proc.wait(10)
        except Exception:
            self.proc.kill()

def local(uri):
    p = urlsplit(uri)
    q = [(k, "127.0.0.1" if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    return urlunsplit((p.scheme, p.netloc, p.path, urlencode(q), ""))

def start_app(base, url, show):
    env = dict(os.environ, NC_STATE_DIR=os.path.join(base, "mac"), NC_PORT="45910", NC_DEFAULTS_SUITE=SUITE,
               NC_TICKET_FILE=os.path.join(base, "ticket.txt"), NC_PASTEBOARD="studio.ivlis.nearclip.remote-demo-pasteboard",
               NC_TAILNET_CONTROL=url, NC_TAILNET_LOG=os.path.join(base, "mac-tailnet.log"))
    if show:
        env["NC_SHOW"] = show
    log = open(os.path.join(base, "app.log"), "a")
    return subprocess.Popen([APP], env=env, stdout=log, stderr=log)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--show", default="settings:general")
    ap.add_argument("--remote-off", action="store_true", help="leave remote connection off in the app")
    args = ap.parse_args()
    if not os.path.exists(CONTROL):
        subprocess.run([os.path.join(ROOT, "tailnet/build.sh"), "testcontrol"], check=True)
    base = tempfile.mkdtemp(prefix="nearclip-remote-")
    control = subprocess.Popen([CONTROL], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    url = json.loads(control.stdout.readline())["controlURL"]
    print("control", url, "state", base, flush=True)
    for key, val in (("onboardingDone", "true"), ("remoteEnabled", "false" if args.remote_off else "true")):
        subprocess.run(["defaults", "write", SUITE, key, "-bool", val], check=True)
    app = start_app(base, url, "add")
    peer = Peer(base, url)
    ticket = os.path.join(base, "ticket.txt")
    end = time.time() + 30
    while not os.path.exists(ticket) and time.time() < end:
        time.sleep(0.2)
    peer.send(cmd="pair_qr", uri=local(open(ticket).read().strip()))
    peer.wait(lambda e: e.get("ev") == "paired")
    peer.wait(lambda e: e.get("ev") == "peer_up")
    print("paired on the LAN; restarting the peer without LAN dialing", flush=True)
    peer.quit()
    app.terminate(); app.wait(5)
    app = start_app(base, url, args.show)
    peer = Peer(base, url, ["--remote-only"])
    up = peer.wait(lambda e: e.get("ev") == "peer_up", timeout=90)
    print("peer route:", up.get("route"), flush=True)
    print("demo running - commands: text <text> | restart <show> | quit", flush=True)
    for line in sys.stdin:
        parts = line.strip().split(" ", 1)
        if not parts or not parts[0]:
            continue
        if parts[0] == "quit":
            break
        if parts[0] == "text" and len(parts) == 2:
            peer.send(cmd="send_text", text=parts[1])
        elif parts[0] == "restart":
            app.terminate(); app.wait(5)
            app = start_app(base, url, parts[1] if len(parts) > 1 else None)
        print("ok", flush=True)
    peer.quit()
    app.terminate()
    control.stdin.close()

if __name__ == "__main__":
    main()
