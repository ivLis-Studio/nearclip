#!/usr/bin/env python3
"""Android image-transfer acceptance on emulator-5584 (PROTOCOL.md section 6.6).

Installs the debug APK and pairs it with a Mac CLI peer that sends image chunks slowly (--pace, like a weak network),
then checks both directions:
  receiving  the card on top of history ("Preparing…", progress, gone after a cancel, replaced by the clip), the
             progress notification while Nearclip is in the background and its "Copied from …" ending, and the
             failure message when the sender drops off (notification outside the app, snackbar inside it);
  sending    an image shared into Nearclip is announced before it is encoded: the peer sees "preparing" for that id
             before the clip itself.
Run from the repo root:  python3 tools/acceptance/android_transfer.py [--shots DIR]
"""
import argparse, os, shlex, signal, subprocess, sys, tempfile, threading, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit, quote

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from tools.acceptance.android_remote import adb, dump, find, tap, shot, CLI, PKG, APK
from tools.interop.run import Peer

PACE = 900_000  # bytes per second: a 10 MB photo takes about 12 s
PORT = 45931  # the emulator can only dial out, to where it last saw the Mac: keep the peer there across restarts
RECEIVING = ("이미지 받는 중", "Receiving an image")
FAILED = ("이미지를 받지 못했습니다", "Couldn’t receive the image")


class MacPeer(Peer):
    """The interop peer on a fixed port (the interop harness always asks for a free one)."""

    def start(self):
        args = f"{self.cmd} --state {shlex.quote(self.state)} --name {shlex.quote(self.name)} --port {PORT}"
        self.proc = subprocess.Popen(args, shell=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)
        threading.Thread(target=self._read, args=(self.proc.stdout, False), daemon=True).start()
        threading.Thread(target=self._read, args=(self.proc.stderr, True), daemon=True).start()
        ready = self.expect("ready", lambda e: e.get("ev") == "ready", timeout=60)
        self.id, self.port = ready["id"], ready["port"]


def make_image(path, picture, size):
    subprocess.run(["sips", "-s", "format", "png", "-Z", str(size), picture, "--out", path], capture_output=True, check=True)
    return path


def has(words, timeout):
    return find(lambda t: any(w in t for w in words), timeout)


def notification(words, timeout, present=True):
    """Polls the posted notifications (dumpsys; banners are not in the UI dump) for a Nearclip title with one of the
    words. Returns the title, or None. With present=False, waits until no such notification is posted."""
    end = time.time() + timeout
    while True:
        out = adb("shell", "dumpsys", "notification", "--noredact").stdout
        titles = [line.split("android.title=", 1)[1].strip() for line in out.splitlines() if "android.title=" in line]
        hit = next((t for t in titles if any(w in t for w in words)), None)
        if (hit is not None) == present or time.time() > end:
            return hit
        time.sleep(0.25)


def gone(words, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if not any(any(w in t for w in words) for t, _ in dump()):
            return True
        time.sleep(0.3)
    return False


def announce(peer):
    peer.mark()
    peer.send(cmd="announce_image")
    return peer.expect("announced", lambda e: e.get("ev") == "announced")["id"]


def drop(peer, state):
    os.kill(peer.proc.pid, signal.SIGKILL)
    subprocess.run(["pkill", "-9", "-f", state], capture_output=True)


def open_home():
    adb("shell", "am", "start", "-n", PKG + "/.ui.MainActivity")
    time.sleep(1.5)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=tempfile.mkdtemp(prefix="nearclip-android-transfer-"))
    args = ap.parse_args()
    os.makedirs(args.shots, exist_ok=True)
    photos = [make_image(os.path.join(args.shots, f"photo{i}.png"), f"/System/Library/Desktop Pictures/{p}", 3200)
              for i, p in enumerate(("Sonoma.heic", "Mac Yellow.heic", "Radial Sky Blue.heic", "iMac Blue.heic"))]
    print("shots", args.shots, "photos", [os.path.getsize(p) for p in photos], flush=True)
    adb("wait-for-device")
    while adb("shell", "getprop", "sys.boot_completed").stdout.strip() != "1":
        time.sleep(2)
    print(adb("install", "-r", APK).stdout.strip().splitlines()[-1:], flush=True)
    adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
    adb("shell", "wm", "dismiss-keyguard")
    adb("shell", "cmd", "statusbar", "collapse")
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS")
    open_home()
    if find(lambda t: t in ("Get started", "시작하기"), 3):
        tap(lambda t: t in ("Get started", "시작하기"), "get started")
        for _ in range(4):
            if find(lambda t: t in ("Skip for now", "나중에 하기"), 3):
                tap(lambda t: t in ("Skip for now", "나중에 하기"), "skip")
                break
            if find(lambda t: t in ("Continue", "계속"), 2):
                tap(lambda t: t in ("Continue", "계속"), "continue")

    state = tempfile.mkdtemp(prefix="nearclip-android-transfer-mac-")
    cmd = shlex.quote(CLI) + f" --platform mac --pace {PACE}"
    mac = MacPeer("swift", cmd, "MacBook Pro", state=state)
    mac.send(cmd="ticket")
    uri = mac.expect("ticket", lambda e: e.get("ev") == "ticket")["uri"]
    p = urlsplit(uri)
    q = [(k, "10.0.2.2" if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    link = urlunsplit((p.scheme, p.netloc, p.path, urlencode(q, quote_via=quote), ""))
    adb("shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", shlex.quote(link), PKG)
    tap(lambda t: t in ("Pair", "연결"), "confirm pairing")
    mac.expect("paired", lambda e: e.get("ev") == "paired", 30)
    mac.expect("peer up", lambda e: e.get("ev") == "peer_up", 30)
    if find(lambda t: t in ("Done", "완료"), 5):
        tap(lambda t: t in ("Done", "완료"), "pairing done")
    print("paired with a Mac peer", flush=True)
    open_home()

    # 1. In the app: "Preparing…" card, then gone after a cancel (no message).
    a = announce(mac)
    assert has(RECEIVING, 6), "no card for the announced image"
    shot(args.shots, "a1-card-preparing")
    mac.send(cmd="cancel_image", id=a)
    assert gone(RECEIVING, 5), "card still there after the cancel"
    assert not has(FAILED, 1), "a cancel was reported as a failure"
    shot(args.shots, "a2-cancelled")
    print("PASS in-app announce and cancel", flush=True)

    # 2. In the app: the card fills, then the clip takes its place.
    b = announce(mac)
    time.sleep(1.0)
    mac.send(cmd="send_image", path=photos[0], mime="image/png", id=b)
    t0 = time.time()
    time.sleep(4)
    hit = has(("MB",), 3)
    shot(args.shots, "a3-card-receiving")
    print("  card:", hit[0] if hit else None, flush=True)
    assert gone(RECEIVING, 40), "card did not go away"
    print("  arrived after", round(time.time() - t0, 1), "s", flush=True)
    time.sleep(0.8)
    shot(args.shots, "a4-arrived")
    print("PASS in-app progress", flush=True)

    # 3. In the background: a banner when it starts, the bar in the shade, a banner when it is in.
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(1.5)
    adb("logcat", "-c")
    c = announce(mac)
    assert notification(RECEIVING, 5), "no notification for the announced image"
    time.sleep(0.5)
    shot(args.shots, "a5-banner-start")
    mac.send(cmd="send_image", path=photos[1], mime="image/png", id=c)
    t0 = time.time()
    time.sleep(4)
    adb("shell", "cmd", "statusbar", "expand-notifications")
    time.sleep(1.5)
    assert has(RECEIVING, 5), "no progress notification"
    shot(args.shots, "a6-shade-progress")
    adb("shell", "cmd", "statusbar", "collapse")
    done = notification(("에서 복사됨", "Copied from"), 30)
    time.sleep(1.5)  # the banner animation is slow on the software-rendered emulator
    shot(args.shots, "a7-banner-done")
    with open(os.path.join(args.shots, "logcat-background.txt"), "w") as f:
        f.write(adb("logcat", "-d", "-v", "time").stdout)
    print("  notification:", done, flush=True)
    assert done, "no 'Copied from' notification"
    assert notification(RECEIVING, 1, present=False) is None, "progress notification stayed"
    print("  arrived after", round(time.time() - t0, 1), "s", flush=True)
    print("PASS background notification", flush=True)

    # 4. In the background: the sender drops off mid-transfer.
    time.sleep(4.5)
    d = announce(mac)
    mac.send(cmd="send_image", path=photos[2], mime="image/png", id=d)
    time.sleep(4)
    drop(mac, state)
    assert notification(FAILED, 8), "no failure notification"
    time.sleep(1.5)
    shot(args.shots, "a8-banner-failed")
    print("PASS background failure", flush=True)

    # 5. In the app: the same failure as a snackbar.
    mac = MacPeer("swift", cmd, "MacBook Pro", state=state)
    mac.expect("peer up", lambda e: e.get("ev") == "peer_up", 60)
    open_home()
    e = announce(mac)
    mac.send(cmd="send_image", path=photos[3], mime="image/png", id=e)
    time.sleep(3.5)
    shot(args.shots, "a9-card-before-drop")
    drop(mac, state)
    assert has(FAILED, 8), "no failure snackbar"
    shot(args.shots, "a10-snackbar-failed")
    print("PASS in-app failure", flush=True)

    # 6. Sending: an image shared into Nearclip is announced before it is read and encoded. The shell cannot grant a
    #    MediaStore URI to the app, so the debug build's own FileProvider serves the file (run-as).
    mac = MacPeer("swift", shlex.quote(CLI) + " --platform mac", "MacBook Pro", state=state)
    mac.expect("peer up", lambda e: e.get("ev") == "peer_up", 60)
    name = f"nc-share-{int(time.time())}.png"
    adb("push", photos[1], "/data/local/tmp/" + name)
    adb("shell", f"run-as {PKG} cp /data/local/tmp/{name} files/nearclip/blobs/{name}")
    mac.mark()
    adb("shell", "am", "start", "-a", "android.intent.action.SEND", "-t", "image/png", "--eu", "android.intent.extra.STREAM",
        f"content://{PKG}.files/blobs/{name}", "-n", PKG + "/.ui.SendActivity")
    prep = mac.expect("announcement", lambda e: e.get("ev") == "transfer" and e.get("state") == "preparing", 20)
    t_prep = time.time()
    first = mac.expect("progress", lambda e: e.get("ev") == "transfer" and e.get("id") == prep["id"] and e.get("total", 0) > 0, 30)
    t_first = time.time()
    clip = mac.expect("clip", lambda e: e.get("ev") == "clip" and e.get("id") == prep["id"], 40)
    print("  announced", prep["id"][:8], "; size known", round(t_first - t_prep, 2), "s later (", first["total"],
          "bytes ); clip", round(time.time() - t_prep, 2), "s after the announcement", flush=True)
    time.sleep(1)
    shot(args.shots, "a11-shared")
    adb("shell", f"run-as {PKG} rm files/nearclip/blobs/{name}")
    adb("shell", "rm", "/data/local/tmp/" + name)
    print("PASS sending announces first", flush=True)
    mac.quit()
    print("PASS android transfer; screenshots:", args.shots, flush=True)


if __name__ == "__main__":
    main()
