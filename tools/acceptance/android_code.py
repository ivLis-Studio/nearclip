#!/usr/bin/env python3
"""Android verification codes on emulator-5584 (PROTOCOL.md §6.7).

Clears and installs the debug APK, walks the first-run screens (the verification-code card among the permissions),
allows notification access through adb (what the user does in Settings), pairs it with a Mac CLI peer, then checks
both directions:
  sending    a text message with a code (adb emu sms send) reaches the Mac as a code clip (otp) holding just the code;
             a message without a code sends nothing; the same code again is not sent twice;
  hidden     Android 15+ hides codes it recognises from listeners it does not trust: Nearclip says so (notification,
             Settings), and after "Let Nearclip see codes" (here the same command through adb) the next code arrives;
  receiving  a code from the Mac is offered, never copied on its own: a notification with Copy while Nearclip is in
             the background, a banner with Copy and Not now over whatever screen of Nearclip is open.

  python3 tools/acceptance/android_code.py [--shots DIR]
"""
import argparse, os, shlex, subprocess, sys, tempfile, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit, quote

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from tools.acceptance.android_remote import adb, dump, find, tap, shot, CLI, PKG, APK
from tools.acceptance.android_transfer import MacPeer, notification, open_home, gone

LISTENER = PKG + "/" + PKG + ".service.CodeListenerService"
ARRIVED = ("인증번호가 도착했어요", "Verification code from", "verification code arrived")
HIDDEN = ("인증번호를 보내지 못했어요", "Couldn’t send a verification code")
ROW = ("인증번호 자동 전송", "Send verification codes")


def sms(sender, text):
    out = adb("emu", "sms", "send", sender, text)
    print("  sms:", text, "->", (out.stdout + out.stderr).strip() or "sent", flush=True)


def no_clip(peer, seconds, what):
    time.sleep(seconds)
    got = [e for e in peer.events[peer.cursor:] if e.get("ev") == "clip"]
    assert not got, what + ": " + str([(e.get("text"), e.get("otp")) for e in got])
    print("  ok:", what, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=tempfile.mkdtemp(prefix="nearclip-android-code-"))
    args = ap.parse_args()
    os.makedirs(args.shots, exist_ok=True)
    adb("wait-for-device")
    while adb("shell", "getprop", "sys.boot_completed").stdout.strip() != "1":
        time.sleep(2)
    print("android", adb("shell", "getprop", "ro.build.version.release").stdout.strip(),
          "sms app", adb("shell", "cmd", "role", "get-role-holders", "android.app.role.SMS").stdout.strip(), flush=True)
    print(adb("install", "-r", APK).stdout.strip().splitlines()[-1:], flush=True)
    adb("shell", "pm", "clear", PKG)
    adb("shell", "cmd", "appops", "set", PKG, "RECEIVE_SENSITIVE_NOTIFICATIONS", "default")
    adb("shell", "input", "keyevent", "KEYCODE_WAKEUP")
    adb("shell", "wm", "dismiss-keyguard")
    adb("shell", "cmd", "statusbar", "collapse")
    adb("shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS")

    # First run: the permissions step shows the verification-code card; access is allowed through adb meanwhile.
    open_home()
    tap(lambda t: t in ("Get started", "시작하기"), "get started")
    assert find(lambda t: t in ("인증번호 자동 전송", "Verification codes"), 8), "no verification-code card"
    shot(args.shots, "c0-onboarding-permissions")
    adb("shell", "cmd", "notification", "allow_listener", LISTENER)
    time.sleep(1.5)
    adb("shell", "input", "keyevent", "KEYCODE_APP_SWITCH")  # leave and come back: the card checks access on resume
    time.sleep(1)
    open_home()
    time.sleep(1)
    shot(args.shots, "c1-onboarding-allowed")
    tap(lambda t: t in ("Continue", "계속"), "continue")
    tap(lambda t: t in ("Skip for now", "나중에 하기"), "skip")

    state = tempfile.mkdtemp(prefix="nearclip-android-code-mac-")
    mac = MacPeer("swift", shlex.quote(CLI) + " --platform mac", "MacBook Pro", state=state)
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
    listeners = adb("shell", "dumpsys", "notification").stdout
    print("  listener bound:", "CodeListenerService" in listeners.split("Live notification listeners")[-1][:3000], flush=True)

    # Sending: a code in a text message goes to the Mac, with nothing to tap on the phone.
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(1)
    mac.mark()
    sms("15881234", "[Web발신] [네이버] 인증번호 [123456]를 입력해주세요.")
    clip = mac.expect("code from the text message", lambda e: e.get("ev") == "clip" and e.get("text") == "123456", 40)
    assert clip.get("otp") is True, "the code clip lost its otp mark: " + str(clip)
    print("  ok: the Mac got just the code, marked as a code:", clip.get("text"), flush=True)
    time.sleep(1)
    shot(args.shots, "c2-sms-notification")
    mac.mark()
    sms("01012345678", "내일 3시에 회의실에서 봬요")
    no_clip(mac, 6, "a message without a code sends nothing")
    mac.mark()
    sms("15881234", "[Web발신] [네이버] 인증번호 [123456]를 입력해주세요.")
    no_clip(mac, 6, "the same code again is not sent twice")
    mac.mark()
    sms("15447788", "G-482916 is your Google verification code.")
    try:
        clip = mac.expect("an English code", lambda e: e.get("ev") == "clip" and e.get("text") == "482916", 20)
        print("  ok: an English message's code arrives too:", clip.get("text"), clip.get("otp"), flush=True)
    except AssertionError:
        # Hidden by Android (Android 15+ recognises this one as a code): said, then fixed once.
        hidden = notification(HIDDEN, 10)
        assert hidden, "a hidden code was neither sent nor reported"
        print("  ok: Android hid the English code, and Nearclip says so:", hidden, flush=True)
        adb("shell", "cmd", "statusbar", "expand-notifications")
        time.sleep(1.5)
        shot(args.shots, "c2b-codes-hidden-notification")
        adb("shell", "cmd", "statusbar", "collapse")
        open_home()
        tap(lambda t: t in ("설정", "Settings"), "settings")
        scroll_to(ROW)
        shot(args.shots, "c2c-settings-hidden")
        tap(lambda t: t in ROW, "the settings row")
        time.sleep(1.2)
        shot(args.shots, "c2d-sheet-hidden")
        assert find(lambda t: "adb shell cmd appops set" in t, 5), "the sheet shows no command"
        adb("shell", "input", "keyevent", "KEYCODE_BACK")
        out = adb("shell", "cmd", "appops", "set", PKG, "RECEIVE_SENSITIVE_NOTIFICATIONS", "allow")
        print("  adb: cmd appops set … allow", (out.stdout + out.stderr).strip() or "ok", flush=True)
        adb("shell", "input", "keyevent", "KEYCODE_HOME")
        time.sleep(1)
        open_home()  # resuming binds the listener again, so that Android looks at the permission again
        time.sleep(4)
        adb("shell", "input", "keyevent", "KEYCODE_HOME")
        time.sleep(1)
        mac.mark()
        sms("15447789", "G-551199 is your Google verification code.")
        clip = mac.expect("a code after allowing", lambda e: e.get("ev") == "clip" and e.get("text") == "551199", 40)
        assert clip.get("otp") is True
        print("  ok: after allowing it once, the code Android used to hide arrives:", clip.get("text"), flush=True)

    # Receiving in the background: a notification with Copy, never copied on its own.
    adb("shell", "cmd", "statusbar", "collapse")
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(1)
    mac.send(cmd="send_text", text="482915", otp=True)
    title = notification(ARRIVED, 15)
    assert title, "no code notification"
    print("  ok: notification:", title, flush=True)
    adb("shell", "cmd", "statusbar", "expand-notifications")
    time.sleep(1.5)
    shot(args.shots, "c3-code-notification")
    tap(lambda t: t in ("복사", "Copy"), "Copy in the notification")
    time.sleep(1.2)
    shot(args.shots, "c4-code-copied")
    assert notification(ARRIVED, 5, present=False) is None, "the notification stayed after Copy"
    print("  ok: Copy closed the notification", flush=True)
    adb("shell", "cmd", "statusbar", "collapse")

    # Receiving inside the app: a banner with Copy and Not now, over whatever screen is open.
    open_home()
    time.sleep(1.5)
    mac.send(cmd="send_text", text="7712", otp=True)
    hit = find(lambda t: any(w in t for w in ARRIVED), 12)
    assert hit, "no banner for the code"
    print("  ok: banner:", hit[0], flush=True)
    time.sleep(0.8)
    shot(args.shots, "c5-code-banner")
    tap(lambda t: t in ("복사", "Copy"), "Copy in the banner")
    assert gone(ARRIVED, 5), "the banner stayed after Copy"
    print("  ok: Copy in the banner copied the code and closed it", flush=True)
    time.sleep(1)
    mac.send(cmd="send_text", text="135790", otp=True)
    assert find(lambda t: any(w in t for w in ARRIVED), 12), "no banner for the next code"
    tap(lambda t: t in ("나중에", "Not now"), "Not now in the banner")
    assert gone(ARRIVED, 5), "the banner stayed after Not now"
    print("  ok: Not now closed the banner", flush=True)

    # Settings: the row and its sheet.
    tap(lambda t: t in ("설정", "Settings"), "settings")
    scroll_to(ROW)
    shot(args.shots, "c6-settings-row")
    tap(lambda t: t in ROW, "the settings row")
    time.sleep(1)
    shot(args.shots, "c7-settings-sheet")
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    mac.quit()
    print("PASS android code", flush=True)
    print("shots:", args.shots)


def scroll_to(words):
    for _ in range(6):
        if find(lambda t: t in words, 1):
            return
        adb("shell", "input", "swipe", "540", "1800", "540", "900", "300")
        time.sleep(0.6)


if __name__ == "__main__":
    main()

