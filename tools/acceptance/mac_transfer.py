#!/usr/bin/env python3
"""macOS receive-progress acceptance with an isolated instance of the Debug app (PROTOCOL.md section 6.6).

Starts apple/build/dd's Nearclip.app with its own state directory, port, defaults suite and private pasteboard (the
installed app and the real clipboard are left alone), pairs a CLI peer that plays a phone sending image chunks slowly
(--pace, like a weak network) through the app's QR ticket, and screenshots the capsule under the menu bar:
"Preparing…", nothing after a cancel, the progress bar, "Copied from …" in place, the warning when the phone drops off
mid-transfer and "Saved to history" with auto-copy off.

  python3 tools/acceptance/mac_transfer.py [--shots DIR]
"""
import argparse, os, shlex, signal, subprocess, sys, tempfile, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)
from tools.interop.run import Peer

APP = os.path.join(ROOT, "apple/build/dd/Build/Products/Debug/Nearclip.app/Contents/MacOS/Nearclip")
CLI = os.path.join(ROOT, "apple/NearclipKit/.build/release/nearclip-cli")
SUITE = "studio.ivlis.nearclip.transfer-test"
PASTEBOARD = SUITE + "-pasteboard"
PORT = "45910"
PACE = 900_000  # bytes per second: a 10 MB photo takes about 12 s


def make_image(path, picture, size):
    subprocess.run(["sips", "-s", "format", "png", "-Z", str(size), picture, "--out", path], capture_output=True, check=True)
    return path


def snap(dirpath, name):
    """The whole screen and its top-right corner, where the capsule sits (name-toast.png)."""
    full = os.path.join(dirpath, name + ".png")
    subprocess.run(["screencapture", "-x", full], capture_output=True)
    out = subprocess.run(["sips", "-g", "pixelWidth", full], capture_output=True, text=True).stdout
    w = int(out.split("pixelWidth:")[1].split()[0])
    subprocess.run(["sips", "-c", "260", "1000", "--cropOffset", "0", str(w - 1000), full,
                    "--out", os.path.join(dirpath, name + "-toast.png")], capture_output=True)
    print("  shot", name, flush=True)


def local(uri):
    p = urlsplit(uri)
    q = [(k, "127.0.0.1" if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    return urlunsplit((p.scheme, p.netloc, p.path, urlencode(q), ""))


class App:
    def __init__(self, base):
        self.base = base
        self.proc = None

    def start(self, show=None):
        env = dict(os.environ, NC_STATE_DIR=os.path.join(self.base, "mac"), NC_PORT=PORT, NC_DEFAULTS_SUITE=SUITE,
                   NC_TICKET_FILE=os.path.join(self.base, "ticket.txt"), NC_PASTEBOARD=PASTEBOARD)
        if show:
            env["NC_SHOW"] = show
        log = open(os.path.join(self.base, "app.log"), "a")
        self.proc = subprocess.Popen([APP], env=env, stdout=log, stderr=log)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def defaults(*args):
    subprocess.run(["defaults", *args], capture_output=True)


def pasteboard_png(pbtest):
    out = subprocess.run([pbtest, PASTEBOARD, "read"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("png bytes:"):
            return int(line.split(":")[1])
    return 0


def announce(phone):
    phone.mark()
    phone.send(cmd="announce_image")
    return phone.expect("announced", lambda e: e.get("ev") == "announced")["id"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=tempfile.mkdtemp(prefix="nearclip-mac-transfer-"))
    args = ap.parse_args()
    os.makedirs(args.shots, exist_ok=True)
    base = tempfile.mkdtemp(prefix="nearclip-mac-transfer-state-")
    pbtest = os.path.join(base, "pbtest")
    subprocess.run(["swiftc", "-O", os.path.join(ROOT, "apple/tools/pbtest.swift"), "-o", pbtest], check=True,
                   capture_output=True)
    photos = [make_image(os.path.join(args.shots, f"photo{i}.png"), f"/System/Library/Desktop Pictures/{p}", 3200)
              for i, p in enumerate(("Sonoma.heic", "Mac Yellow.heic", "Radial Sky Blue.heic"))]
    print("shots", args.shots, "state", base, "photos", [os.path.getsize(p) for p in photos], flush=True)
    defaults("delete", SUITE)
    defaults("write", SUITE, "onboardingDone", "-bool", "true")
    # The private pasteboard outlives the app: start from text, so an image there can only be this run's.
    subprocess.run([pbtest, PASTEBOARD, "write-text", "nearclip transfer test"], capture_output=True)
    app = App(base)
    phone = None
    try:
        app.start(show="add")
        ticket = os.path.join(base, "ticket.txt")
        end = time.time() + 30
        while not os.path.exists(ticket) and time.time() < end:
            time.sleep(0.2)
        assert os.path.exists(ticket), "no ticket from the app"
        state = os.path.join(base, "phone")
        cmd = shlex.quote(CLI) + f" --platform android --pace {PACE}"
        phone = Peer("swift", cmd, "Galaxy S25", state=state)
        phone.send(cmd="pair_qr", uri=local(open(ticket).read().strip()))
        phone.expect("paired", lambda e: e.get("ev") == "paired", 30)
        phone.expect("peer up", lambda e: e.get("ev") == "peer_up", 30)
        print("paired with the macOS app", flush=True)
        # Close the Add window, so only the capsule changes on screen.
        app.stop()
        app.start()
        phone.mark()
        phone.expect("peer up again", lambda e: e.get("ev") == "peer_up", 60)
        time.sleep(2)

        # 1. Announced, then cancelled: "Preparing…" first, then the capsule goes away without a message.
        a = announce(phone)
        time.sleep(1.5)
        snap(args.shots, "m1-preparing")
        phone.send(cmd="cancel_image", id=a)
        time.sleep(1.2)
        snap(args.shots, "m2-cancelled")

        # 2. Announced, then sent slowly: the bar fills, then "Copied from Galaxy S25" in place.
        b = announce(phone)
        time.sleep(1.0)
        phone.send(cmd="send_image", path=photos[0], mime="image/png", id=b)
        t0 = time.time()
        for name, at in (("m3-receiving-early", 3.0), ("m4-receiving-late", 8.5)):
            time.sleep(max(0.0, t0 + at - time.time()))
            snap(args.shots, name)
        got = 0
        while time.time() < t0 + 60:
            got = pasteboard_png(pbtest)
            if got == os.path.getsize(photos[0]):
                break
            time.sleep(0.2)
        snap(args.shots, "m5-copied")
        print("pasteboard png:", got, "bytes after", round(time.time() - t0, 1), "s", flush=True)
        assert got == os.path.getsize(photos[0]), "the image did not reach the pasteboard"
        time.sleep(0.5)
        snap(args.shots, "m5b-copied-thumbnail")

        # 3. The phone drops off mid-transfer: a warning that says where to copy it again.
        time.sleep(3)
        c = announce(phone)
        phone.send(cmd="send_image", path=photos[1], mime="image/png", id=c)
        time.sleep(4)
        snap(args.shots, "m6-before-drop")
        os.kill(phone.proc.pid, signal.SIGKILL)
        subprocess.run(["pkill", "-9", "-f", state], capture_output=True)
        time.sleep(1.2)
        snap(args.shots, "m7-failed")

        # 4. Auto-copy off: "Image from Galaxy S25 · Saved to history" when it is in.
        time.sleep(4)
        app.stop()
        defaults("write", SUITE, "autoApply", "-bool", "false")
        app.start()
        phone = Peer("swift", cmd, "Galaxy S25", state=state)
        phone.expect("peer up", lambda e: e.get("ev") == "peer_up", 60)
        time.sleep(2)
        d = announce(phone)
        phone.send(cmd="send_image", path=photos[2], mime="image/png", id=d)
        t0 = time.time()
        time.sleep(4)
        snap(args.shots, "m8-receiving-autocopy-off")
        time.sleep(max(0.0, t0 + os.path.getsize(photos[2]) / PACE + 1.0 - time.time()))
        snap(args.shots, "m9-saved-to-history")
        print("PASS mac transfer; screenshots:", args.shots, flush=True)
    finally:
        if phone:
            phone.quit()
        app.stop()
        defaults("delete", SUITE)


if __name__ == "__main__":
    main()
