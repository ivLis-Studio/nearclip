#!/usr/bin/env python3
"""iOS remote-connection acceptance on the simulator (PROTOCOL.md section 10).

Runs a throwaway Tailscale control server, a CLI peer ("Galaxy S25") with remote connection on and the UI test
NearclipFlowTests/testRemoteConnection. Once the iPhone's node appears in the tailnet, the peer restarts
LAN-unreachable (--remote-only) and sends a clip: the test must show "Connected - Remote" and receive the clip.

  python3 apple/tools/ios_remote.py [--lang ko] [--sim <udid>]
"""
import argparse, json, os, subprocess, sys, tempfile, threading, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLI = os.path.join(ROOT, "apple/NearclipKit/.build/release/nearclip-cli")
CONTROL = os.path.join(ROOT, "tailnet/out/nctestcontrol")

class Peer:
    def __init__(self, state, url, extra=()):
        self.events, self.cond = [], threading.Condition()
        args = [CLI, "--state", state, "--name", "Galaxy S25", "--platform", "android", "--port", "0",
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
            if ev.get("ev") in ("paired", "peer_up", "peer_down", "tailnet", "ticket"):
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

def local(uri):
    p = urlsplit(uri)
    q = [(k, "127.0.0.1" if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    return urlunsplit((p.scheme, p.netloc, p.path, urlencode(q), ""))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", default="ko")
    ap.add_argument("--sim", default="3955421C-2710-4341-8A7F-CF0D22F868AF")
    args = ap.parse_args()
    base = tempfile.mkdtemp(prefix="nearclip-ios-remote-")
    shots = os.path.join(base, "shots")
    control = subprocess.Popen([CONTROL], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    url = json.loads(control.stdout.readline())["controlURL"]
    state = os.path.join(base, "s25")
    peer = Peer(state, url)
    peer.wait(lambda e: e.get("ev") == "ready", 30)
    peer.send(cmd="ticket")
    link = local(peer.wait(lambda e: e.get("ev") == "ticket", 10)["uri"])
    expect = "원격으로 받은 클립 ✈️"
    env = dict(os.environ, TEST_RUNNER_NC_PAIR_LINK=link, TEST_RUNNER_NC_TAILNET_CONTROL=url, TEST_RUNNER_NC_SHOTS=shots,
               TEST_RUNNER_NC_LANG=args.lang, TEST_RUNNER_NC_EXPECT=expect)
    cmd = ["xcodebuild", "test", "-project", os.path.join(ROOT, "apple/Nearclip.xcodeproj"), "-scheme", "NearclipiOS",
           "-derivedDataPath", os.path.join(ROOT, "apple/build/dd"), "-destination", f"id={args.sim}",
           "-only-testing:NearclipiOSUITests/NearclipFlowTests/testRemoteConnection",
           "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "420"]
    log = open(os.path.join(base, "xcodebuild.log"), "w")
    test = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
    print("state", base, "control", url, flush=True)
    try:
        peer.wait(lambda e: e.get("ev") == "paired", 300)
        peer.wait(lambda e: e.get("ev") == "tailnet" and e.get("peers", 0) >= 1, 240)
        print("iPhone node joined the tailnet; peer goes LAN-unreachable", flush=True)
        peer.quit()
        peer = Peer(state, url, ["--remote-only"])
        up = peer.wait(lambda e: e.get("ev") == "peer_up", 120)
        print("peer route:", up.get("route"), flush=True)
        time.sleep(1)
        peer.send(cmd="send_text", text=expect)
    except TimeoutError:
        print("timed out waiting for the iPhone", flush=True)
    rc = test.wait()
    print("xcodebuild exit", rc, "shots", shots, flush=True)
    os.system(f"grep -E 'Test Case|error:|failed|passed' {os.path.join(base, 'xcodebuild.log')} | tail -8")
    peer.quit()
    control.stdin.close()

if __name__ == "__main__":
    main()
