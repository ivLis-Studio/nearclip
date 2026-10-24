#!/usr/bin/env python3
"""Live Shizuku opt-in acceptance on emulator-5584, using an actual copy in Contacts and a Swift LAN peer.

Prerequisites: install the current Nearclip APK, finish onboarding, install/start Shizuku. This script never
installs or enables Shizuku on a user's physical phone. A fresh temporary peer is used; the emulator is re-paired.
The feature is disabled at the end. Run from the repo root:
    python3 tools/acceptance/android_capture.py
"""
import os
import shlex
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from urllib.parse import parse_qsl, quote, urlencode, urlsplit, urlunsplit

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from tools.acceptance.android_remote import adb, dump, tap, find, shot, CLI, PKG
from tools.interop.run import Peer

TITLE = "복사한 항목 바로 Nearclip에 불러오기"


def open_settings():
    adb("shell", "am", "start", "-n", PKG + "/.ui.MainActivity",
        "--es", "studio.ivlis.nearclip.extra.ROUTE", "settings")
    time.sleep(1.5)


def copy_in_contacts(text):
    adb("shell", "am", "force-stop", "com.google.android.contacts")
    adb("shell", "am", "start", "-a", "android.intent.action.INSERT", "-t", "vnd.android.cursor.dir/contact")
    time.sleep(1)
    # Dismiss a stray pointer tooltip/context menu before focusing the real field.
    adb("shell", "input", "keyevent", "KEYCODE_ESCAPE")
    tap(lambda t: t in ("First name", "이름"), "Contacts first-name field")
    adb("shell", "input", "keycombination", "113", "29")  # Ctrl+A
    adb("shell", "input", "text", text)
    time.sleep(1)
    # Contacts formats person names while typing. Compare with the actual field contents the user copies.
    adb("shell", "uiautomator", "dump", "/sdcard/nc-copy-ui.xml")
    root = ET.fromstring(adb("shell", "cat", "/sdcard/nc-copy-ui.xml").stdout)
    copied = next(n.get("text") for n in root.iter("node") if n.get("class") == "android.widget.EditText")
    assert copied and copied not in ("First name", "이름"), "nothing entered in Contacts"
    adb("shell", "input", "keycombination", "113", "29")
    time.sleep(0.4)
    adb("shell", "input", "keycombination", "113", "31")  # Ctrl+C
    return copied


def main():
    shots = tempfile.mkdtemp(prefix="nearclip-capture-")
    print("screenshots:", shots, flush=True)
    adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
    adb("shell", "wm", "dismiss-keyguard")
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS")
    open_settings()
    tap(lambda t: t == TITLE, "instant capture setup")
    if find(lambda t: t == "끄기", 2):
        tap(lambda t: t == "끄기", "turn off before test")
    else:
        adb("shell", "input", "keyevent", "KEYCODE_BACK")
    assert find(lambda t: t == "다른 앱에서 복사하는 즉시 내 기기로 보냅니다. Shizuku가 필요합니다.", 5), "feature enabled before opt-in"

    peer = Peer("swift", shlex.quote(CLI) + " --platform mac", "Capture test Mac")
    try:
        peer.send(cmd="ticket")
        uri = peer.expect("ticket", lambda e: e.get("ev") == "ticket")["uri"]
        parts = urlsplit(uri)
        query = [(k, "10.0.2.2" if k == "h" else v) for k, v in parse_qsl(parts.query, keep_blank_values=True)]
        link = urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(query, quote_via=quote), ""))
        adb("shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", shlex.quote(link), PKG)
        tap(lambda t: t in ("Pair", "연결"), "confirm pairing")
        peer.expect("paired", lambda e: e.get("ev") == "paired", timeout=30)
        peer.expect("peer up", lambda e: e.get("ev") == "peer_up", timeout=30)
        tap(lambda t: t in ("Done", "완료"), "pairing done")
        print("PASS: LAN peer paired", flush=True)

        # Default behavior: copies stay on this phone until an existing send action is used.
        text = "capture-off-" + str(time.time_ns())
        peer.mark()
        text = copy_in_contacts(text)
        time.sleep(2)
        assert not any(e.get("ev") == "clip" and e.get("text") == text for e in peer.events[peer.cursor:])
        print("PASS: off means no background send", flush=True)

        open_settings()
        tap(lambda t: t == TITLE, "open setup")
        shot(shots, "01-setup")
        if find(lambda t: t == "허용하기", 2):
            tap(lambda t: t == "허용하기", "ask Shizuku")
            tap(lambda t: t in ("Allow all the time", "항상 허용"), "grant Shizuku permission")
            time.sleep(1)
        else:
            tap(lambda t: t == "켜기", "opt in")
        assert find(lambda t: t == "켜짐 · 복사하는 즉시 보냅니다.", 6), "feature not enabled after opt-in"
        if find(lambda t: t == "끄기", 2):
            shot(shots, "02-enabled")
            tap(lambda t: t == "완료", "close setup")

        text = "capture-background-" + str(time.time_ns())
        peer.mark()
        text = copy_in_contacts(text)
        e = peer.expect("background copy", lambda e: e.get("ev") == "clip" and e.get("text") == text, timeout=12)
        assert e.get("live"), e
        shot(shots, "03-copied-in-contacts")
        time.sleep(0.7)
        assert sum(e.get("ev") == "clip" and e.get("text") == text for e in peer.events[peer.cursor:]) == 1
        print("PASS: real Contacts copy reached Mac peer once while Nearclip was in background", flush=True)

        # Receiving a clip writes our marker to the system clipboard. The background listener must not send it back.
        text = "capture-incoming-" + str(time.time_ns())
        peer.mark()
        peer.send(cmd="send_text", text=text)
        time.sleep(2)
        assert not any(e.get("ev") == "clip" and e.get("text") == text for e in peer.events[peer.cursor:])
        open_settings()
        adb("shell", "input", "keyevent", "KEYCODE_BACK")
        assert find(lambda t: text in t, 6), "incoming clip missing from Nearclip history"
        print("PASS: incoming clip arrived without an echo", flush=True)

        open_settings()
        tap(lambda t: t == TITLE, "feature details")
        tap(lambda t: t == "끄기", "disable feature")
        text = "capture-disabled-" + str(time.time_ns())
        peer.mark()
        text = copy_in_contacts(text)
        time.sleep(2)
        assert not any(e.get("ev") == "clip" and e.get("text") == text for e in peer.events[peer.cursor:])
        print("PASS: disabling stops background capture", flush=True)
    finally:
        peer.quit()
    print("PASS android instant capture; screenshots:", shots, flush=True)


if __name__ == "__main__":
    main()
