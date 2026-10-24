#!/usr/bin/env python3
"""Android remote-connection acceptance on emulator-5584 (PROTOCOL.md section 10).

Starts a throwaway Tailscale control server reachable from the emulator, installs the debug APK, points it at the
server (files/tailnet-control.txt, debug builds only), pairs it with a CLI peer through a nearclip:// link, turns on
"Sync across networks" through the UI, then makes the peer LAN-unreachable (--remote-only). The app must reach it
through the tailnet: Devices shows "Connected - Remote" and a clip from the peer arrives.

  python3 tools/acceptance/android_remote.py [--shots DIR]
"""
import argparse, json, os, re, subprocess, sys, tempfile, threading, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit, quote

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ADB = [os.path.expanduser("~/Library/Android/sdk/platform-tools/adb"), "-s", "emulator-5584"]
CLI = os.path.join(ROOT, "apple/NearclipKit/.build/release/nearclip-cli")
CONTROL = os.path.join(ROOT, "tailnet/out/nctestcontrol")
APK = os.path.join(ROOT, "android/app/build/outputs/apk/debug/app-debug.apk")
PKG = "studio.ivlis.nearclip"

def adb(*a, **kw):
    return subprocess.run(ADB + list(a), capture_output=True, text=True, **kw)

def dump():
    adb("shell", "uiautomator", "dump", "/sdcard/nc-ui.xml")
    xml = adb("shell", "cat", "/sdcard/nc-ui.xml").stdout
    out = []
    for m in re.finditer(r'<node [^>]*>', xml):
        n = m.group(0)
        t = re.search(r' text="([^"]*)"', n)
        d = re.search(r' content-desc="([^"]*)"', n)
        b = re.search(r' bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        out.append(((t.group(1) if t else "") or (d.group(1) if d else ""), tuple(map(int, b.groups())) if b else None))
    return out

def find(pred, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        for text, b in dump():
            if b and text and pred(text):
                return text, b
        time.sleep(0.7)
    return None

def tap(pred, what, timeout=20):
    hit = find(pred, timeout)
    if not hit:
        raise AssertionError("not on screen: " + what + " / " + repr([t for t, _ in dump() if t][:30]))
    b = hit[1]
    adb("shell", "input", "tap", str((b[0] + b[2]) // 2), str((b[1] + b[3]) // 2))
    time.sleep(0.8)
    return hit[0]

def shot(dirpath, name):
    os.makedirs(dirpath, exist_ok=True)
    with open(os.path.join(dirpath, name + ".png"), "wb") as f:
        f.write(subprocess.run(ADB + ["exec-out", "screencap", "-p"], capture_output=True).stdout)

class Peer:
    def __init__(self, state, url, extra=()):
        self.events, self.cond = [], threading.Condition()
        args = [CLI, "--state", state, "--name", "MacBook Pro", "--platform", "mac", "--port", "0",
                "--tailnet", os.path.join(state, "tailnet"), "--tailnet-control", url, *extra]
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
            if ev.get("ev") in ("paired", "peer_up", "peer_down", "tailnet"):
                print("  [peer]", ev, flush=True)

    def wait(self, pred, timeout):
        end = time.time() + timeout
        with self.cond:
            while True:
                for e in self.events:
                    if pred(e):
                        return e
                if time.time() > end:
                    raise TimeoutError
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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=tempfile.mkdtemp(prefix="nearclip-android-remote-"))
    args = ap.parse_args()
    lan = subprocess.run(["ipconfig", "getifaddr", "en0"], capture_output=True, text=True).stdout.strip() or "10.0.2.2"
    control = subprocess.Popen([CONTROL, "-listen", "0.0.0.0", "-ip", lan], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    url = json.loads(control.stdout.readline())["controlURL"]
    print("control", url, "shots", args.shots, flush=True)
    adb("wait-for-device")
    while adb("shell", "getprop", "sys.boot_completed").stdout.strip() != "1":
        time.sleep(2)
    print(adb("install", "-r", APK).stdout.strip().splitlines()[-1:], flush=True)
    adb("shell", "am", "force-stop", PKG)
    # One string, so the device shell (not adb) parses the quotes. A node from an earlier run is moved aside.
    adb("shell", f"run-as {PKG} sh -c 'mv files/tailnet files/tailnet-old-$(date +%s) 2>/dev/null; echo {url} > files/tailnet-control.txt'")
    assert url in adb("shell", f"run-as {PKG} cat files/tailnet-control.txt").stdout, "could not write tailnet-control.txt"
    adb("shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS")
    adb("shell", "am", "start", "-n", PKG + "/.ui.MainActivity")
    time.sleep(3)
    if find(lambda t: t in ("Get started", "시작하기"), 4):
        tap(lambda t: t in ("Get started", "시작하기"), "get started")
        for _ in range(4):
            if find(lambda t: t in ("Skip for now", "나중에 하기"), 3):
                tap(lambda t: t in ("Skip for now", "나중에 하기"), "skip")
                break
            if find(lambda t: t in ("Continue", "계속"), 2):
                tap(lambda t: t in ("Continue", "계속"), "continue")
    state = tempfile.mkdtemp(prefix="nearclip-android-peer-")
    peer = Peer(state, url)
    peer.wait(lambda e: e.get("ev") == "ready", 30)
    peer.send(cmd="ticket")
    uri = peer.wait(lambda e: e.get("ev") == "ticket", 10)["uri"]
    p = urlsplit(uri)
    q = [(k, "10.0.2.2" if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    link = urlunsplit((p.scheme, p.netloc, p.path, urlencode(q, quote_via=quote), ""))
    adb("shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "'" + link + "'", PKG)
    tap(lambda t: t in ("Pair", "연결"), "pair button")
    peer.wait(lambda e: e.get("ev") == "paired", 60)
    peer.wait(lambda e: e.get("ev") == "peer_up", 60)
    time.sleep(1)
    for t in ("Done", "완료", "OK", "확인"):
        if find(lambda x: x == t, 1):
            tap(lambda x: x == t, t)
            break
    tap(lambda t: t in ("Settings", "설정"), "settings")
    status_lines = ("Starting…", "준비 중…", "Sign in to Tailscale to finish turning this on.", "Tailscale에 로그인하면 켜집니다.")
    if not find(lambda t: t in status_lines or t.startswith("On · ") or t.startswith("켜짐 · ") or "remote connection" in t.lower()
                or "원격 연결을 시작" in t, 3):
        tap(lambda t: t in ("Sync across networks", "다른 네트워크에서도 동기화"), "remote toggle")
    on = find(lambda t: t.startswith("On · ") or t.startswith("켜짐 · "), 90)
    assert on, "remote connection did not come up: " + repr([t for t, _ in dump() if t][:30])
    print("app:", on[0], flush=True)
    time.sleep(1)
    shot(args.shots, "50-settings-remote-on")
    peer.wait(lambda e: e.get("ev") == "tailnet" and e.get("peers", 0) >= 1, 120)
    print("emulator node joined the tailnet; peer goes LAN-unreachable", flush=True)
    peer.quit()
    peer = Peer(state, url, ["--remote-only"])
    up = peer.wait(lambda e: e.get("ev") == "peer_up", 120)
    print("peer route:", up.get("route"), flush=True)
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    time.sleep(1)
    tap(lambda t: "connected" in t.lower() or "연결됨" in t, "devices chip")
    remote = find(lambda t: t in ("Connected · Remote", "연결됨 · 원격"), 30)
    assert remote, "device not shown as remote: " + repr([t for t, _ in dump() if t][:30])
    time.sleep(1)
    shot(args.shots, "51-devices-remote")
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    text = "LTE에서도 도착 ✈️"
    peer.send(cmd="send_text", text=text)
    got = find(lambda t: text in t, 30)
    assert got, "clip did not arrive"
    time.sleep(1)
    shot(args.shots, "52-home-remote-clip")
    print("PASS android remote", flush=True)
    peer.quit()
    control.stdin.close()

if __name__ == "__main__":
    main()
