#!/usr/bin/env python3
"""Windows receive-progress acceptance in the Parallels "Windows 11" VM (PROTOCOL.md section 6.6).

Needs the Debug build of the app in the guest (windows/NOTES.md). Pairs the app with a Mac CLI peer that plays a
phone sending image chunks slowly (--pace, like a weak network) and takes screenshots of the toast: "Preparing…"
after an announcement, nothing after a cancel, the progress bar while chunks arrive, "Copied from …" in place when
the image is in, the warning when the phone drops off mid-transfer, and "Saved to history" with auto-copy off.

  python3 tools/acceptance/windows_transfer.py [--shots DIR]
"""
import argparse, os, shlex, signal, subprocess, sys, tempfile, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit, quote

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from tools.acceptance.windows_remote import guest, launch, shot, EXE, HOST, CLI
from tools.interop.run import Peer

PACE = 900_000  # bytes per second: a 10 MB photo takes about 12 s


def make_image(path, picture, size):
    subprocess.run(["sips", "-s", "format", "png", "-Z", str(size), picture, "--out", path], capture_output=True, check=True)
    return path


def crop(dirpath, name):
    """The bottom-right corner of a VM screenshot, where the toast sits (name-toast.png next to the full shot)."""
    full = os.path.join(dirpath, name + ".png")
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", full], capture_output=True, text=True).stdout
    w = int(out.split("pixelWidth:")[1].split()[0])
    h = int(out.split("pixelHeight:")[1].split()[0])
    cw, ch = min(w, 900), min(h, 420)
    subprocess.run(["sips", "-c", str(ch), str(cw), "--cropOffset", str(h - ch), str(w - cw), full,
                    "--out", os.path.join(dirpath, name + "-toast.png")], capture_output=True)


def snap(dirpath, name):
    shot(dirpath, name)
    crop(dirpath, name)
    print("  shot", name, flush=True)


def settings(**values):
    sets = "".join(f"$s | Add-Member -NotePropertyName {k} -NotePropertyValue ${'true' if v else 'false'} -Force; "
                   for k, v in values.items())
    return guest(f"""
        if (Get-Process Nearclip -ErrorAction SilentlyContinue) {{ & '{EXE}' --quit; Start-Sleep 3 }}
        Get-Process Nearclip -ErrorAction SilentlyContinue | Stop-Process -Force
        $f = Join-Path (Join-Path $env:LOCALAPPDATA 'Nearclip') 'settings.json'
        $s = Get-Content $f -Raw | ConvertFrom-Json
        {sets}
        $s | ConvertTo-Json -Depth 5 | Set-Content $f
        'settings updated'
    """)


def clipboard_image():
    return guest("$i = Get-Clipboard -Format Image; if ($i) { '' + $i.Width + 'x' + $i.Height } else { 'none' }")


def announce(phone):
    phone.mark()
    phone.send(cmd="announce_image")
    return phone.expect("announced", lambda e: e.get("ev") == "announced")["id"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=tempfile.mkdtemp(prefix="nearclip-windows-transfer-"))
    args = ap.parse_args()
    os.makedirs(args.shots, exist_ok=True)
    photos = [make_image(os.path.join(args.shots, f"photo{i}.png"), f"/System/Library/Desktop Pictures/{p}", 3200)
              for i, p in enumerate(("Sonoma.heic", "Mac Yellow.heic", "Radial Sky Blue.heic"))]
    print("shots", args.shots, "photos", [os.path.getsize(p) for p in photos], flush=True)
    print(settings(showToasts=True, autoApply=True, syncImages=True, paused=False, remoteEnabled=False), flush=True)
    launch("--background")
    time.sleep(6)
    state = tempfile.mkdtemp(prefix="nearclip-windows-transfer-phone-")
    cmd = shlex.quote(CLI) + f" --platform android --pace {PACE}"
    phone = Peer("swift", cmd, "Galaxy S25", state=state)
    phone.send(cmd="ticket")
    uri = phone.expect("ticket", lambda e: e.get("ev") == "ticket")["uri"]
    p = urlsplit(uri)
    q = [(k, HOST if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    launch(urlunsplit((p.scheme, p.netloc, p.path, urlencode(q, quote_via=quote), "")))
    phone.expect("paired", lambda e: e.get("ev") == "paired", 60)
    phone.expect("peer up", lambda e: e.get("ev") == "peer_up", 60)
    print("paired with the Windows app", flush=True)
    time.sleep(3)
    snap(args.shots, "w0-after-pairing")

    # 1. Announced, then cancelled: "Preparing…" first, then the toast goes away without a message.
    a = announce(phone)
    time.sleep(1.5)
    snap(args.shots, "w1-preparing")
    phone.send(cmd="cancel_image", id=a)
    time.sleep(1.2)
    snap(args.shots, "w2-cancelled")

    # 2. Announced, then sent slowly: the bar fills, then "Copied from Galaxy S25" in place.
    guest("Set-Clipboard -Value 'nearclip transfer test'")
    time.sleep(1)
    b = announce(phone)
    time.sleep(1.0)
    phone.send(cmd="send_image", path=photos[0], mime="image/png", id=b)
    t0 = time.time()
    for name, at in (("w3-receiving-early", 3.0), ("w4-receiving-late", 8.5)):
        time.sleep(max(0.0, t0 + at - time.time()))
        snap(args.shots, name)
    got = "none"
    while time.time() < t0 + 60:
        got = clipboard_image()
        if got not in ("", "none"):
            break
        time.sleep(0.3)
    snap(args.shots, "w5-copied")
    print("clipboard image:", got, "after", round(time.time() - t0, 1), "s", flush=True)
    assert got not in ("", "none"), "the image did not reach the Windows clipboard"

    # 3. The phone drops off mid-transfer: a warning that says where to copy it again.
    time.sleep(3)
    c = announce(phone)
    phone.send(cmd="send_image", path=photos[1], mime="image/png", id=c)
    time.sleep(4)
    snap(args.shots, "w6-before-drop")
    os.kill(phone.proc.pid, signal.SIGKILL)
    subprocess.run(["pkill", "-9", "-f", state], capture_output=True)
    time.sleep(1.5)
    snap(args.shots, "w7-failed")

    # 4. Auto-copy off: "Image from Galaxy S25 · Saved to history" when it is in.
    time.sleep(4)
    print(settings(autoApply=False), flush=True)
    launch("--background")
    time.sleep(5)
    phone = Peer("swift", cmd, "Galaxy S25", state=state)
    phone.expect("peer up", lambda e: e.get("ev") == "peer_up", 60)
    time.sleep(2)
    d = announce(phone)
    phone.send(cmd="send_image", path=photos[2], mime="image/png", id=d)
    t0 = time.time()
    time.sleep(4)
    snap(args.shots, "w8-receiving-autocopy-off")
    size = os.path.getsize(photos[2])
    time.sleep(max(0.0, t0 + size / PACE + 1.0 - time.time()))
    snap(args.shots, "w9-saved-to-history")
    print(settings(autoApply=True), flush=True)
    launch("--background")
    phone.quit()
    print("PASS windows transfer; screenshots:", args.shots, flush=True)


if __name__ == "__main__":
    main()
