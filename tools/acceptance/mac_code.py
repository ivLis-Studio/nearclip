#!/usr/bin/env python3
"""macOS: a verification code from a phone is offered, never pasted on its own (PROTOCOL.md §6.7).

Runs an isolated instance of the Debug app (apple/build/dd: own state, port, defaults suite and private pasteboard, so
the Nearclip you use and the real clipboard are left alone), pairs a CLI peer playing an iPhone ("준서의 iPhone"),
and checks the capsule under the menu bar:
  1. a code arrives: the pasteboard is not written, and the capsule asks "Copy it?";
  2. Copy (pressed through Accessibility, apple/tools/axpress.swift) puts the code on the pasteboard;
  3. another code, Not Now: the capsule goes, and the pasteboard keeps the first code;
  4. with arrival notices turned off, a code still asks;
  5. an ordinary clip from the phone is still copied on its own.

  python3 tools/acceptance/mac_code.py [--shots DIR]
"""
import argparse, os, shlex, subprocess, sys, tempfile, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)
from tools.acceptance.mac_transfer import App, CLI, SUITE, PASTEBOARD, defaults, local, snap
from tools.interop.run import Peer


def build_helper(base, name):
    out = os.path.join(base, name)
    subprocess.run(["swiftc", "-O", os.path.join(ROOT, "apple/tools", name + ".swift"), "-o", out], check=True,
                   capture_output=True)
    return out


def pasteboard_text(pbtest):
    out = subprocess.run([pbtest, PASTEBOARD, "read"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("text: "):
            return line[len("text: "):]
    return None


def capsule(winlist, pid):
    """The capsule's bounds, if it is on screen (the app's only window at the status-bar level)."""
    out = subprocess.run([winlist, str(pid)], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split(" ", 6)
        if len(parts) >= 6 and int(parts[1]) == 25:
            return tuple(int(v) for v in parts[2:6])
    return None


def wait_for(cond, seconds, what):
    end = time.time() + seconds
    while time.time() < end:
        v = cond()
        if v:
            return v
        time.sleep(0.25)
    raise AssertionError(what)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=tempfile.mkdtemp(prefix="nearclip-mac-code-"))
    args = ap.parse_args()
    os.makedirs(args.shots, exist_ok=True)
    base = tempfile.mkdtemp(prefix="nearclip-mac-code-state-")
    pbtest, winlist, axpress = (build_helper(base, n) for n in ("pbtest", "winlist", "axpress"))
    defaults("delete", SUITE)
    defaults("write", SUITE, "onboardingDone", "-bool", "true")
    subprocess.run([pbtest, PASTEBOARD, "write-text", "before the code"], capture_output=True)
    app = App(base)
    phone = None
    try:
        app.start(show="add")
        ticket = os.path.join(base, "ticket.txt")
        wait_for(lambda: os.path.exists(ticket), 30, "no ticket from the app")
        phone = Peer("swift", shlex.quote(CLI) + " --platform ios", "준서의 iPhone", state=os.path.join(base, "phone"))
        phone.send(cmd="pair_qr", uri=local(open(ticket).read().strip()))
        phone.expect("paired", lambda e: e.get("ev") == "paired", 30)
        phone.expect("peer up", lambda e: e.get("ev") == "peer_up", 30)
        print("paired with the macOS app", flush=True)
        app.stop()  # closes the Add window, so only the capsule changes on screen
        phone.mark()
        app.start()
        phone.expect("peer up again", lambda e: e.get("ev") == "peer_up", 60)
        time.sleep(2)
        pid = app.proc.pid

        # 1. A code is offered, not pasted.
        phone.send(cmd="send_text", text="482915", otp=True)
        wait_for(lambda: capsule(winlist, pid), 10, "no capsule for the code")
        time.sleep(0.6)
        snap(args.shots, "mac-code")
        assert pasteboard_text(pbtest) == "before the code", "the code went to the pasteboard on its own"
        print("  ok: the capsule asks, and the pasteboard was not written", flush=True)

        # 2. Copy puts it on the pasteboard.
        r = subprocess.run([axpress, str(pid), "toast.code.copy"], capture_output=True, text=True)
        print("  ", r.stdout.strip(), flush=True)
        wait_for(lambda: pasteboard_text(pbtest) == "482915", 5, "Copy did not copy the code: " + str(pasteboard_text(pbtest)))
        time.sleep(0.4)
        snap(args.shots, "mac-code-copied")
        print("  ok: Copy put the code on the pasteboard", flush=True)

        # 3. Another code, Not Now: the capsule goes, the pasteboard keeps the first code.
        time.sleep(2.5)
        phone.send(cmd="send_text", text="7712", otp=True)
        wait_for(lambda: capsule(winlist, pid), 10, "no capsule for the second code")
        time.sleep(0.5)
        r = subprocess.run([axpress, str(pid), "toast.code.dismiss"], capture_output=True, text=True)
        print("  ", r.stdout.strip(), flush=True)
        wait_for(lambda: capsule(winlist, pid) is None, 5, "the capsule stayed after Not Now")
        assert pasteboard_text(pbtest) == "482915", "Not Now changed the pasteboard"
        print("  ok: Not Now closed the capsule and left the pasteboard alone", flush=True)

        # 4. Arrival notices off: a code still asks.
        app.stop()
        defaults("write", SUITE, "showToasts", "-bool", "false")
        phone.mark()
        app.start()
        phone.expect("peer up again", lambda e: e.get("ev") == "peer_up", 60)
        time.sleep(2)
        pid = app.proc.pid
        phone.send(cmd="send_text", text="135790", otp=True)
        wait_for(lambda: capsule(winlist, pid), 10, "no capsule with arrival notices off")
        print("  ok: the capsule asks with arrival notices off", flush=True)
        subprocess.run([axpress, str(pid), "toast.code.dismiss"], capture_output=True)

        # 5. An ordinary clip is still copied on its own.
        plain = "plain text " + time.strftime("%H%M%S")
        phone.send(cmd="send_text", text=plain)
        wait_for(lambda: pasteboard_text(pbtest) == plain, 10, "an ordinary clip was not copied")
        print("  ok: an ordinary clip is still copied on its own", flush=True)
        print("PASS mac code", flush=True)
    finally:
        if phone:
            phone.quit()
        app.stop()
        defaults("delete", SUITE)
        print("shots:", args.shots)


if __name__ == "__main__":
    main()

