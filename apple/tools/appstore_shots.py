#!/usr/bin/env python3
"""App Store screenshots of the iOS app on the simulator, with clean demo devices and clips.

Three CLI peers stand in for the user's other devices ("MacBook Pro", an iPad and another iPhone). They pair into
one group and send a short, realistic history. Then a newly created simulator runs the UI test
NearclipFlowTests/testOnboardingPairSyncAndSend, which pairs through the Mac's link (catch-up brings the history),
sends a clip with the Paste button and saves screenshots: 06-home-history, 08-sent, 09-devices, 10-settings,
11-add-device (and the onboarding pages). promo/appstore.sh frames them for the store.

  python3 apple/tools/appstore_shots.py --device iphone --lang en --out promo/out/appstore/raw/iphone-en
  python3 apple/tools/appstore_shots.py --device ipad --lang ko --out promo/out/appstore/raw/ipad-ko

Each run creates a dedicated, disposable simulator. Existing user simulators are never erased. The status bar is pinned to 9:41, full battery and signal.
"""
import argparse, json, os, re, shlex, subprocess, sys, tempfile, threading, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)
from tools.interop.run import Peer, local_uri

CLI = shlex.quote(os.path.join(ROOT, "apple/NearclipKit/.build/release/nearclip-cli"))
PHOTO = os.path.join(ROOT, "promo/assets/lisbon.jpg")
DEVICES = {
    "iphone": ("iPhone", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"),
    "ipad": ("iPad", "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"),
}
COPY = {
    "en": {"ipad": "iPad", "send": "See you at 8!", "clips": [
        ("iphone", "image", None),
        ("ipad", "text", "Slides for tomorrow's 10 AM meeting"),
        ("mac", "text", "https://github.com/ivLis-Studio/nearclip"),
        ("iphone", "text", "482913"),
        ("mac", "text", "41-1 Yeonmujang-gil, Seongdong-gu, Seoul"),
        ("ipad", "text", "#4C5BF5"),
        ("mac", "text", "Meeting moved to 8 PM"),
    ]},
    "ko": {"ipad": "iPad", "send": "8시에 봐요!", "clips": [
        ("iphone", "image", None),
        ("ipad", "text", "내일 10시 회의 자료 공유드립니다"),
        ("mac", "text", "https://github.com/ivLis-Studio/nearclip"),
        ("iphone", "text", "482913"),
        ("mac", "text", "서울 성동구 연무장길 41-1"),
        ("ipad", "text", "#4C5BF5"),
        ("mac", "text", "회의 8시로 변경됐어요"),
    ]},
}


def sh(*args, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check).stdout


def simulator(kind):
    name, devtype = DEVICES[kind]
    runtimes = json.loads(sh("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    runtime = [r for r in runtimes if r.get("platform") == "iOS" and r.get("isAvailable")][-1]["identifier"]
    return sh("xcrun", "simctl", "create", name, devtype, runtime).strip()


def fresh(udid, lang):
    sh("xcrun", "simctl", "shutdown", udid, check=False)
    # The system language too: the iPad status bar shows the date in it.
    plist = os.path.expanduser(f"~/Library/Developer/CoreSimulator/Devices/{udid}/data/Library/Preferences/.GlobalPreferences.plist")
    os.makedirs(os.path.dirname(plist), exist_ok=True)
    sh("plutil", "-create", "binary1", plist, check=False) if not os.path.exists(plist) else None
    sh("plutil", "-replace", "AppleLanguages", "-json", json.dumps([lang]), plist)
    sh("plutil", "-replace", "AppleLocale", "-string", "ko_KR" if lang == "ko" else "en_US", plist)
    sh("xcrun", "simctl", "boot", udid)
    sh("xcrun", "simctl", "bootstatus", udid, "-b")
    sh("xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode",
       "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--batteryState", "charged",
       "--batteryLevel", "100")


def pair(inviter, joiner):
    inviter.mark()
    inviter.send(cmd="ticket")
    link = local_uri(inviter.expect("ticket", lambda e: e.get("ev") == "ticket")["uri"])
    joiner.send(cmd="pair_qr", uri=link)
    joiner.expect("paired", lambda e: e.get("ev") == "paired", 30)


def bonjour_port(name, timeout=8):
    """The port the app on the simulator listens on (it shares the Mac's network), from its DNS-SD advertisement."""
    proc = subprocess.Popen(["dns-sd", "-L", name, "_nearclip._tcp", "local."], stdout=subprocess.PIPE, text=True)
    found = []

    def read():
        for line in proc.stdout:
            m = re.search(r"can be reached at \S+:(\d+)", line)
            if m:
                found.append(int(m.group(1)))
                return
    t = threading.Thread(target=read, daemon=True)
    t.start()
    t.join(timeout)
    proc.kill()
    return found[0] if found else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", choices=DEVICES, default="iphone")
    ap.add_argument("--lang", choices=COPY, default="en")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    copy = COPY[args.lang]
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    base = tempfile.mkdtemp(prefix="nearclip-appstore-")
    udid = simulator(args.device)
    print("simulator", udid, flush=True)
    fresh(udid, args.lang)

    peers = {
        "mac": Peer("swift", CLI + " --platform mac", "MacBook Pro", state=os.path.join(base, "mac")),
        "ipad": Peer("swift", CLI + " --platform ios", copy["ipad"], state=os.path.join(base, "ipad")),
        "iphone": Peer("swift", CLI + " --platform ios", "iPhone", state=os.path.join(base, "iphone")),
    }
    try:
        pair(peers["mac"], peers["ipad"])
        pair(peers["mac"], peers["iphone"])
        time.sleep(2)
        for who, kind, value in copy["clips"]:
            if kind == "image":
                peers[who].send(cmd="send_image", path=PHOTO, mime="image/jpeg")
            else:
                peers[who].send(cmd="send_text", text=value)
            time.sleep(1.5)
        time.sleep(2)

        mac = peers["mac"]
        mac.mark()
        mac.send(cmd="ticket")
        link = local_uri(mac.expect("ticket", lambda e: e.get("ev") == "ticket")["uri"])
        env = dict(os.environ, TEST_RUNNER_NC_PAIR_LINK=link, TEST_RUNNER_NC_SHOTS=out, TEST_RUNNER_NC_LANG=args.lang,
                   TEST_RUNNER_NC_SEND_TEXT=copy["send"])
        cmd = ["xcodebuild", "test", "-project", os.path.join(ROOT, "apple/Nearclip.xcodeproj"), "-scheme", "NearclipiOS",
               "-derivedDataPath", os.path.join(ROOT, "apple/build/dd"), "-destination", f"id={udid}",
               "-only-testing:NearclipiOSUITests/NearclipFlowTests/testOnboardingPairSyncAndSend",
               "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "600"]
        with open(os.path.join(base, "xcodebuild.log"), "w") as log:
            test = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
            # The fixture peers are headless and do not browse DNS-SD: once the simulator has joined through the
            # Mac's link, dial it from both so the screenshots show every device connected.
            try:
                mac.expect("simulator joined", lambda e: e.get("ev") == "paired", 900)
                port = bonjour_port(DEVICES[args.device][0])
                print("simulator listens on", port, flush=True)
                if port:
                    for k in ("ipad", "iphone"):
                        peers[k].send(cmd="connect", host="127.0.0.1", port=port)
            except AssertionError as e:
                print("peer:", e, flush=True)
            rc = test.wait()
        # Preserve the renderer's stable input filename when the UI test adds onboarding steps.
        empty = os.path.join(out, "05-home-empty.png")
        if rc == 0 and os.path.exists(empty):
            import shutil
            shutil.copyfile(empty, os.path.join(out, "04-home-empty.png"))
        print("xcodebuild exit", rc, "log", os.path.join(base, "xcodebuild.log"), flush=True)
        os.system(f"grep -E 'Test Case|error:|failed|passed' {shlex.quote(os.path.join(base, 'xcodebuild.log'))} | tail -6")
        print("shots", out, sorted(os.listdir(out)), flush=True)
        return rc
    finally:
        for p in peers.values():
            p.quit()
        sh("xcrun", "simctl", "shutdown", udid, check=False)
        sh("xcrun", "simctl", "delete", udid, check=False)


if __name__ == "__main__":
    sys.exit(main())

