#!/usr/bin/env python3
"""iOS verification-code acceptance on the simulator (PROTOCOL.md §6.7).

Runs a CLI peer ("MacBook Pro") and the UI test NearclipFlowTests/testCodeOffer, which pairs through the peer's link.
Once paired, the peer sends a code (otp) and, a while later, another one: the test checks the banner ("A verification
code arrived from MacBook Pro. Copy it?"), that nothing is copied on its own, Copy and Not Now, and the Shortcuts guide
in Settings, and saves screenshots.

With --intent it runs NearclipFlowTests/testSendCodeIntent instead: the app runs "Send Verification Code" on a text
message with a code and on one without (Debug-only nearclip://debug-send-code), and the peer checks that just the code
arrived, marked as a code, and nothing else.

  python3 apple/tools/ios_code.py [--lang ko] [--sim <udid>] [--intent]
"""
import argparse, os, shlex, subprocess, sys, tempfile, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)
from tools.interop.run import Peer
from apple.tools.ios_transfer import CLI, local


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", default="ko")
    ap.add_argument("--sim", default="3955421C-2710-4341-8A7F-CF0D22F868AF")
    ap.add_argument("--intent", action="store_true")
    args = ap.parse_args()
    base = tempfile.mkdtemp(prefix="nearclip-ios-code-")
    shots = os.path.join(base, "shots")
    mac = Peer("swift", shlex.quote(CLI) + " --platform mac", "MacBook Pro", state=os.path.join(base, "mac"))
    mac.send(cmd="ticket")
    link = local(mac.expect("ticket", lambda e: e.get("ev") == "ticket")["uri"])
    env = dict(os.environ, TEST_RUNNER_NC_PAIR_LINK=link, TEST_RUNNER_NC_SHOTS=shots, TEST_RUNNER_NC_LANG=args.lang)
    cmd = ["xcodebuild", "test", "-project", os.path.join(ROOT, "apple/Nearclip.xcodeproj"), "-scheme", "NearclipiOS",
           "-derivedDataPath", os.path.join(ROOT, "apple/build/dd"), "-destination", f"id={args.sim}",
           "-only-testing:NearclipiOSUITests/NearclipFlowTests/" + ("testSendCodeIntent" if args.intent else "testCodeOffer"),
           "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "420"]
    log = open(os.path.join(base, "xcodebuild.log"), "w")
    test = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
    print("state", base, flush=True)
    ok = True
    try:
        mac.expect("paired", lambda e: e.get("ev") == "paired", 400)
        mac.expect("peer up", lambda e: e.get("ev") == "peer_up", 60)
        print("paired with the iPhone", flush=True)
        if args.intent:
            mac.mark()
            clip = mac.expect("code from the iPhone", lambda e: e.get("ev") == "clip" and e.get("src") != mac.id, 60)
            print("the iPhone sent:", clip.get("text"), "otp", clip.get("otp"), flush=True)
            ok = clip.get("text") == "482915" and clip.get("otp") is True
            time.sleep(12)
            more = [e.get("text") for e in mac.events[mac.cursor:] if e.get("ev") == "clip" and e is not clip]
            print("then:", more or "nothing", flush=True)
            ok = ok and not more
        else:
            time.sleep(5)
            mac.send(cmd="send_text", text="482915", otp=True)
            print("sent a code", flush=True)
            time.sleep(18)
            mac.send(cmd="send_text", text="7712", otp=True)
            print("sent another code", flush=True)
    except AssertionError as e:
        print("peer:", e, flush=True)
        ok = False
    rc = test.wait()
    print("xcodebuild exit", rc, "shots", shots, "| peer checks", "PASS" if ok else "FAIL", flush=True)
    os.system(f"grep -E 'Test Case|error:|failed|passed' {shlex.quote(os.path.join(base, 'xcodebuild.log'))} | tail -8")
    mac.quit()


if __name__ == "__main__":
    main()

