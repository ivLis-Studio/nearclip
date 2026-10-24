#!/usr/bin/env python3
"""Remote connection against the real Tailscale service: a manual check that needs a person.

The other remote acceptance scripts use a throwaway control server (tailnet/out/nctestcontrol). This one uses
login.tailscale.com, so the two nodes it creates join a real tailnet. It runs an isolated Nearclip.app (macOS Debug
build with its own state directory, defaults suite and private pasteboard) and the Android debug app on emulator-5584:

1. The emulator joins the Mac's group through a nearclip:// link: the LAN path, as when pairing at home.
2. The Mac app restarts on another port with remote connection on, so that path is gone and the two can only meet
   through the tailnet (the emulator never learns the new port; the Mac cannot reach the emulator's LAN address).
3. Both apps ask for a Tailscale sign-in: click "Sign in with Tailscale" in the Mac app's settings window, and open
   the emulator's link printed here. Approve both with the same Tailscale account.
4. Checks: the emulator shows the Mac as "Connected - Remote" and a clip goes each way (Mac -> Android through the
   private pasteboard, Android -> Mac through the share sheet). The WireGuard path is read from both nodes' logs.

  python3 tools/acceptance/real_remote.py [--shots DIR]
stdin while running:  m2a <text> | a2m <text> | path | shot <name> | logout | quit
Sign both nodes out afterwards: "Sign out of Tailscale" in the Mac app, `logout` here for the emulator.
"""
import argparse, os, re, shutil, subprocess, sys, tempfile, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit, quote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from android_remote import APK, PKG, adb, dump, find, tap, shot  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP = os.path.join(ROOT, "apple/build/dd/Build/Products/Debug/Nearclip.app/Contents/MacOS/Nearclip")
SUITE = "studio.ivlis.nearclip.real-demo"
PASTEBOARD = "studio.ivlis.nearclip.real-demo-pasteboard"
AUTH = re.compile(r"https://login\.tailscale\.com/a/[0-9A-Za-z]+")
SIGNED_OUT = ("Sign in to Tailscale to finish turning this on.", "Tailscale에 로그인하면 켜집니다.")


class MacApp:
    def __init__(self, base):
        self.base = base
        self.log = os.path.join(base, "mac-tailnet.log")
        self.proc = None

    def start(self, port, show):
        env = dict(os.environ, NC_STATE_DIR=os.path.join(self.base, "mac"), NC_PORT=str(port), NC_DEFAULTS_SUITE=SUITE,
                   NC_TICKET_FILE=os.path.join(self.base, "ticket.txt"), NC_PASTEBOARD=PASTEBOARD,
                   NC_TAILNET_LOG=self.log, NC_SHOW=show)
        env.pop("NC_TAILNET_CONTROL", None)  # the real control server
        out = open(os.path.join(self.base, "app.log"), "a")
        self.proc = subprocess.Popen([APP], env=env, stdout=out, stderr=out)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def tailnet_log(self):
        try:
            with open(self.log, errors="replace") as f:
                return f.read()
        except OSError:
            return ""


def emulator_log():
    return adb("shell", f"run-as {PKG} cat files/tailnet.log").stdout


def running(log):
    # LocalBackend logs "Switching ipn state Starting -> Running (WantRunning=true, nm=true)".
    states = re.findall(r"Switching ipn state \w+ -> (\w+)", log)
    return bool(states) and states[-1] == "Running"


def last_auth(log):
    m = AUTH.findall(log)
    return m[-1] if m else None


def path_report(mac):
    for name, log in (("Mac", mac.tailnet_log()), ("Android", emulator_log())):
        lines = [l for l in log.splitlines() if "magicsock" in l and "now using" in l]
        print(f"  {name} WireGuard path:", lines[-1].strip() if lines else "DERP relay (no direct path logged)", flush=True)
    if shutil.which("tailscale"):
        st = subprocess.run(["tailscale", "status"], capture_output=True, text=True).stdout
        for line in st.splitlines():
            if "nearclip-" in line:
                print("  tailscale status:", " ".join(line.split()), flush=True)


def settings_screen():
    adb("shell", "am", "start", "-n", PKG + "/.ui.MainActivity")
    time.sleep(1)
    for _ in range(3):
        if find(lambda t: t in ("Sync across networks", "다른 네트워크에서도 동기화"), 2):
            return
        if find(lambda t: t in ("Settings", "설정"), 2):
            tap(lambda t: t in ("Settings", "설정"), "settings")
        else:
            adb("shell", "input", "keyevent", "KEYCODE_BACK")
            time.sleep(0.8)


def home_screen():
    adb("shell", "am", "start", "-n", PKG + "/.ui.MainActivity")
    time.sleep(1)
    for _ in range(3):
        if find(lambda t: t in ("Settings", "설정"), 2):
            return
        adb("shell", "input", "keyevent", "KEYCODE_BACK")
        time.sleep(0.8)


def mac_to_android(pb, shots, text):
    home_screen()
    subprocess.run([pb, PASTEBOARD, "write-text", text], check=True, capture_output=True)
    got = find(lambda t: text in t, 40)
    print("Mac -> Android:", "arrived" if got else "MISSING", repr(text), flush=True)
    if got:
        time.sleep(1)
        shot(shots, "r3-android-clip-from-mac")
    return bool(got)


def android_to_mac(pb, text):
    adb("shell", "am", "start", "-a", "android.intent.action.SEND", "-t", "text/plain",
        "--es", "android.intent.extra.TEXT", "'" + text + "'", "-n", PKG + "/.ui.SendActivity")
    end = time.time() + 40
    while time.time() < end:
        out = subprocess.run([pb, PASTEBOARD, "read"], capture_output=True, text=True).stdout
        if text in out:
            print("Android -> Mac: arrived on the Mac clipboard", repr(text), flush=True)
            return True
        time.sleep(0.5)
    print("Android -> Mac: MISSING", repr(text), flush=True)
    return False


def logout_android():
    settings_screen()
    tap(lambda t: t in ("Sign out of Tailscale", "Tailscale에서 로그아웃"), "sign out")
    gone = find(lambda t: t in SIGNED_OUT, 30)
    print("emulator node signed out" if gone else "emulator sign-out not confirmed", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=tempfile.mkdtemp(prefix="nearclip-real-shots-"))
    args = ap.parse_args()
    base = tempfile.mkdtemp(prefix="nearclip-real-")
    pb = os.path.join(base, "pbtest")
    subprocess.run(["swiftc", "-O", os.path.join(ROOT, "apple/tools/pbtest.swift"), "-o", pb], check=True)
    print("state", base, "shots", args.shots, flush=True)
    for key, val in (("onboardingDone", "true"), ("remoteEnabled", "false")):
        subprocess.run(["defaults", "write", SUITE, key, "-bool", val], check=True)
    mac = MacApp(base)
    mac.start(45910, "add")
    try:
        run(args, base, pb, mac)
    finally:
        mac.stop()


def run(args, base, pb, mac):
    # The emulator gets a fresh node for the real control server; its earlier test node is moved aside.
    adb("wait-for-device")
    while adb("shell", "getprop", "sys.boot_completed").stdout.strip() != "1":
        time.sleep(2)
    print(adb("install", "-r", APK).stdout.strip().splitlines()[-1:], flush=True)
    adb("shell", "am", "force-stop", PKG)
    stamp = int(time.time())
    adb("shell", f"run-as {PKG} sh -c 'cd files && for f in tailnet tailnet.log tailnet-control.txt; "
                 f"do [ -e $f ] && mv $f $f.old-{stamp}; done; true'")
    left = adb("shell", f"run-as {PKG} sh -c '[ -e files/tailnet-control.txt ] && echo test-control || echo real'").stdout
    assert "real" in left, "could not move files/tailnet-control.txt aside"
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

    # 1. Pair over the LAN path (the emulator reaches the Mac at 10.0.2.2).
    ticket = os.path.join(base, "ticket.txt")
    end = time.time() + 30
    while not os.path.exists(ticket) and time.time() < end:
        time.sleep(0.2)
    p = urlsplit(open(ticket).read().strip())
    q = [(k, "10.0.2.2" if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    link = urlunsplit((p.scheme, p.netloc, p.path, urlencode(q, quote_via=quote), ""))
    adb("shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "'" + link + "'", PKG)
    tap(lambda t: t in ("Pair", "연결"), "pair button")
    assert find(lambda t: t in ("Done", "완료"), 60), "pairing did not finish: " + repr([t for t, _ in dump() if t][:30])
    tap(lambda t: t in ("Done", "완료"), "done")
    print("paired over the LAN path", flush=True)

    # 2. The LAN path goes away; remote connection comes on.
    mac.stop()
    subprocess.run(["defaults", "write", SUITE, "remoteEnabled", "-bool", "true"], check=True)
    mac.start(45911, "settings:general")
    settings_screen()
    if not find(lambda t: t in SIGNED_OUT or t.startswith(("On · ", "켜짐 · ")), 5):
        tap(lambda t: t in ("Sync across networks", "다른 네트워크에서도 동기화"), "remote toggle")

    # 3. Sign-in on both.
    url, end = None, time.time() + 90
    while not url and time.time() < end:
        url = last_auth(emulator_log())
        time.sleep(1)
    assert url, "the emulator node did not ask for a sign-in"
    shot(args.shots, "r0-android-needs-login")
    print("EMULATOR SIGN-IN:", url, flush=True)
    print("MAC SIGN-IN: click 'Sign in with Tailscale' in the Nearclip settings window", flush=True)
    seen, end = set(), time.time() + 900
    while len(seen) < 2 and time.time() < end:
        for name, log in (("Mac", mac.tailnet_log()), ("Android", emulator_log())):
            if name not in seen and running(log):
                seen.add(name)
                print(f"{name} node is on the tailnet", flush=True)
        time.sleep(2)
    assert len(seen) == 2, "sign-in did not finish on both"
    settings_screen()
    on = find(lambda t: t.startswith(("On · ", "켜짐 · ")), 60)
    print("emulator settings:", on[0] if on else "?", flush=True)
    shot(args.shots, "r1-android-settings-on")

    # 4. The route and a clip each way.
    home_screen()
    tap(lambda t: "connected" in t.lower() or "연결됨" in t, "devices chip", timeout=120)
    remote = find(lambda t: t in ("Connected · Remote", "연결됨 · 원격"), 120)
    assert remote, "Mac not shown as remote: " + repr([t for t, _ in dump() if t][:30])
    print("emulator devices:", remote[0], flush=True)
    time.sleep(1)
    shot(args.shots, "r2-android-devices-remote")
    mac_to_android(pb, args.shots, "Mac에서 다른 네트워크로 ✈️ " + time.strftime("%H:%M:%S"))
    android_to_mac(pb, "Android에서 Mac으로 🛰️ " + time.strftime("%H:%M:%S"))
    path_report(mac)
    print("ready - commands: m2a <text> | a2m <text> | path | shot <name> | logout | quit", flush=True)
    for line in sys.stdin:
        cmd, _, rest = line.strip().partition(" ")
        if cmd == "quit":
            break
        elif cmd == "m2a" and rest:
            mac_to_android(pb, args.shots, rest)
        elif cmd == "a2m" and rest:
            android_to_mac(pb, rest)
        elif cmd == "path":
            path_report(mac)
        elif cmd == "shot" and rest:
            shot(args.shots, rest)
        elif cmd == "logout":
            logout_android()
        print("ok", flush=True)


if __name__ == "__main__":
    main()
