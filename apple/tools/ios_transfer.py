#!/usr/bin/env python3
"""iOS receive-progress acceptance on the simulator (PROTOCOL.md section 6.6).

Runs a CLI peer ("MacBook Pro") that sends image chunks slowly (--pace, like a weak network) and the UI test
NearclipFlowTests/testIncomingImageProgress, which pairs through the peer's link. Once paired, the peer announces an
image and sends it: the test checks the "Receiving an image from MacBook Pro…" card, its progress and the
"Copied from MacBook Pro" toast that takes its place, and saves screenshots.

  python3 apple/tools/ios_transfer.py [--lang ko] [--sim <udid>]
"""
import argparse, os, shlex, subprocess, sys, tempfile, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)
from tools.interop.run import Peer

CLI = os.path.join(ROOT, "apple/NearclipKit/.build/release/nearclip-cli")
PACE = 900_000  # bytes per second: a 10 MB photo takes about 12 s


def local(uri):
    from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit
    p = urlsplit(uri)
    q = [(k, "127.0.0.1" if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    return urlunsplit((p.scheme, p.netloc, p.path, urlencode(q), ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", default="ko")
    ap.add_argument("--sim", default="3955421C-2710-4341-8A7F-CF0D22F868AF")
    args = ap.parse_args()
    base = tempfile.mkdtemp(prefix="nearclip-ios-transfer-")
    shots = os.path.join(base, "shots")
    photo = os.path.join(base, "photo.png")
    subprocess.run(["sips", "-s", "format", "png", "-Z", "3200", "/System/Library/Desktop Pictures/Sonoma.heic",
                    "--out", photo], capture_output=True, check=True)
    mac = Peer("swift", shlex.quote(CLI) + f" --platform mac --pace {PACE}", "MacBook Pro", state=os.path.join(base, "mac"))
    mac.send(cmd="ticket")
    link = local(mac.expect("ticket", lambda e: e.get("ev") == "ticket")["uri"])
    env = dict(os.environ, TEST_RUNNER_NC_PAIR_LINK=link, TEST_RUNNER_NC_SHOTS=shots, TEST_RUNNER_NC_LANG=args.lang)
    cmd = ["xcodebuild", "test", "-project", os.path.join(ROOT, "apple/Nearclip.xcodeproj"), "-scheme", "NearclipiOS",
           "-derivedDataPath", os.path.join(ROOT, "apple/build/dd"), "-destination", f"id={args.sim}",
           "-only-testing:NearclipiOSUITests/NearclipFlowTests/testIncomingImageProgress",
           "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "420"]
    log = open(os.path.join(base, "xcodebuild.log"), "w")
    test = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
    print("state", base, flush=True)
    try:
        mac.expect("paired", lambda e: e.get("ev") == "paired", 400)
        mac.expect("peer up", lambda e: e.get("ev") == "peer_up", 60)
        print("paired with the iPhone", flush=True)
        time.sleep(4)
        mac.mark()
        mac.send(cmd="announce_image")
        image_id = mac.expect("announced", lambda e: e.get("ev") == "announced")["id"]
        time.sleep(4)
        mac.send(cmd="send_image", path=photo, mime="image/png", id=image_id)
        print("sending", os.path.getsize(photo), "bytes at", PACE, "bytes/s", flush=True)
    except AssertionError as e:
        print("peer:", e, flush=True)
    rc = test.wait()
    print("xcodebuild exit", rc, "shots", shots, flush=True)
    os.system(f"grep -E 'Test Case|error:|failed|passed' {shlex.quote(os.path.join(base, 'xcodebuild.log'))} | tail -8")
    mac.quit()


if __name__ == "__main__":
    main()
