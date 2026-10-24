#!/usr/bin/env python3
"""Windows remote-connection acceptance in the Parallels "Windows 11" VM (PROTOCOL.md section 10).

Needs the Debug build of the app in the guest (windows/NOTES.md). Starts a throwaway Tailscale control server on
10.211.55.2, points the app at it (tailnet-control.txt, Debug builds only), turns remote connection on in
settings.json, pairs it with a CLI peer through a nearclip:// link, then makes the peer LAN-unreachable
(--remote-only). The app must reach it through the tailnet and put the peer's clip on the Windows clipboard.

  python3 tools/acceptance/windows_remote.py [--shots DIR]
"""
import argparse, base64, json, os, subprocess, sys, tempfile, threading, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit, quote

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLI = os.path.join(ROOT, "apple/NearclipKit/.build/release/nearclip-cli")
CONTROL = os.path.join(ROOT, "tailnet/out/nctestcontrol")
HOST = "10.211.55.2"
EXE = r"C:\dev\nearclip\windows\src\Nearclip.App\bin\ARM64\Debug\net10.0-windows10.0.22621.0\win-arm64\Nearclip.exe"

def guest(script, timeout=60):
    full = "$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; " + script
    enc = base64.b64encode(full.encode("utf-16-le")).decode()
    r = subprocess.run(["prlctl", "exec", "Windows 11", "--current-user", "powershell", "-NoProfile", "-NonInteractive",
                        "-EncodedCommand", enc], capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip()

def launch(args=""):
    # Processes started directly by prlctl exec die with it; WMI-created ones survive.
    cmd = f'"{EXE}" {args}'.replace("'", "''")
    return guest(f"(Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{{CommandLine='{cmd}'}}).ReturnValue")

class Peer:
    def __init__(self, state, url, extra=()):
        self.events, self.cond = [], threading.Condition()
        args = [CLI, "--state", state, "--name", "MacBook Pro", "--platform", "mac", "--port", "0",
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
            if ev.get("ev") in ("paired", "peer_up", "peer_down", "tailnet", "pair_failed"):
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

def shot(dirpath, name):
    os.makedirs(dirpath, exist_ok=True)
    subprocess.run(["prlctl", "capture", "Windows 11", "--file", os.path.join(dirpath, name + ".png")], capture_output=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=tempfile.mkdtemp(prefix="nearclip-windows-remote-"))
    args = ap.parse_args()
    control = subprocess.Popen([CONTROL, "-listen", "0.0.0.0", "-ip", HOST], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    url = json.loads(control.stdout.readline())["controlURL"]
    print("control", url, "shots", args.shots, flush=True)
    print(guest(f"""
        if (Get-Process Nearclip -ErrorAction SilentlyContinue) {{ & '{EXE}' --quit; Start-Sleep 2 }}
        $d = Join-Path $env:LOCALAPPDATA 'Nearclip'
        if (Test-Path (Join-Path $d 'tailnet')) {{ Rename-Item (Join-Path $d 'tailnet') ('tailnet-old-' + (Get-Date -Format yyyyMMddHHmmss)) }}
        Set-Content -Path (Join-Path $d 'tailnet-control.txt') -Value '{url}' -NoNewline
        $s = Get-Content (Join-Path $d 'settings.json') -Raw | ConvertFrom-Json
        $s | Add-Member -NotePropertyName remoteEnabled -NotePropertyValue $true -Force
        $s | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $d 'settings.json')
        'prepared'
    """), flush=True)
    launch("--background")
    time.sleep(6)
    state = tempfile.mkdtemp(prefix="nearclip-windows-peer-")
    peer = Peer(state, url)
    peer.wait(lambda e: e.get("ev") == "ready", 30)
    peer.send(cmd="ticket")
    uri = peer.wait(lambda e: e.get("ev") == "ticket", 10)["uri"]
    p = urlsplit(uri)
    q = [(k, HOST if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    link = urlunsplit((p.scheme, p.netloc, p.path, urlencode(q, quote_via=quote), ""))
    launch(link)
    peer.wait(lambda e: e.get("ev") == "paired", 60)
    peer.wait(lambda e: e.get("ev") == "peer_up", 60)
    print("paired over the LAN", flush=True)
    peer.wait(lambda e: e.get("ev") == "tailnet" and e.get("peers", 0) >= 1, 120)
    print("Windows node joined the tailnet; peer goes LAN-unreachable", flush=True)
    peer.quit()
    peer = Peer(state, url, ["--remote-only"])
    up = peer.wait(lambda e: e.get("ev") == "peer_up", 120)
    print("peer route:", up.get("route"), flush=True)
    assert up.get("route") == "remote", up
    text = "원격으로 Windows에 도착 ✈️ " + time.strftime("%H:%M:%S")
    peer.send(cmd="send_text", text=text)
    got = ""
    for _ in range(20):
        time.sleep(1)
        got = guest("Get-Clipboard")
        if text in got:
            break
    print("guest clipboard:", got, flush=True)
    assert text in got, "clip did not reach the Windows clipboard"
    launch("--show settings:general")
    time.sleep(3)
    # The remote section is below the fold: Tab moves focus down and the page scrolls with it.
    keys = [{"key": 23, "event": e} for _ in range(6) for e in ("press", "release")]
    subprocess.run(["prlctl", "send-key-event", "Windows 11", "--json"], input=json.dumps(keys), text=True, capture_output=True)
    time.sleep(1.5)
    shot(args.shots, "60-settings-remote-on")
    launch("--show settings:devices")
    time.sleep(3)
    shot(args.shots, "61-devices-remote")
    print("PASS windows remote", flush=True)
    peer.quit()
    control.stdin.close()

if __name__ == "__main__":
    main()
