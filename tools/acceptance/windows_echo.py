#!/usr/bin/env python3
"""Windows: the same content is never copied around twice (DESIGN.md §4.3), in the Parallels "Windows 11" VM.

Needs the Debug build of the app in the guest (windows/NOTES.md). Pairs the app with a Mac CLI peer playing a phone,
then checks what the bugs looked like:
  1. the same text set on the clipboard again (also with CRLF) is not sent again; new text is;
  2. a clip from the phone, put back on the clipboard by another sync app (Link to Windows), is not sent back —
     and the phone sending it once more does not write the clipboard again (no endless loop);
  3. a screenshot tool setting one picture twice, as a bitmap and then as PNG, sends one image;
  4. an image from the phone that the clipboard already holds is not written again.

  python3 tools/acceptance/windows_echo.py
"""
import base64, os, shlex, subprocess, sys, tempfile, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit, quote

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from tools.acceptance.windows_remote import guest, launch, EXE, HOST, CLI
from tools.acceptance.windows_transfer import settings
from tools.interop.run import Peer

SEQ = "Add-Type -Namespace W -Name U -MemberDefinition '[DllImport(\"user32.dll\")] public static extern uint GetClipboardSequenceNumber();'; "


def guest_sta(script, timeout=60):
    """Like guest(), in a single-threaded apartment (Windows Forms clipboard)."""
    full = "$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; " + script
    enc = base64.b64encode(full.encode("utf-16-le")).decode()
    r = subprocess.run(["prlctl", "exec", "Windows 11", "--current-user", "powershell", "-STA", "-NoProfile", "-NonInteractive",
                        "-EncodedCommand", enc], capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip()


def seq():
    return int(guest(SEQ + "[W.U]::GetClipboardSequenceNumber()").splitlines()[-1])


def set_text(value):
    guest("Set-Clipboard -Value '" + value.replace("'", "''") + "'")


PICTURE = """
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$bmp = New-Object System.Drawing.Bitmap 320, 200
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(255, 40, 90, 200))
$g.FillEllipse([System.Drawing.Brushes]::Orange, {x}, 30, 120, 120)
$g.Dispose()
"""


def set_bitmap(x=40):
    """What a screenshot tool does first: the picture as a bitmap."""
    return guest_sta(PICTURE.replace("{x}", str(x)) + "[System.Windows.Forms.Clipboard]::SetImage($bmp); 'bitmap set'")


def set_png(x=40):
    """…and then again, the same picture as PNG (plus the bitmap)."""
    return guest_sta(PICTURE.replace("{x}", str(x)) + """
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$do = New-Object System.Windows.Forms.DataObject
$do.SetData('PNG', $false, $ms)
$do.SetData([System.Windows.Forms.DataFormats]::Bitmap, $true, $bmp)
[System.Windows.Forms.Clipboard]::SetDataObject($do, $true)
'png set'
""")


def clips(phone):
    return [e for e in phone.events[phone.cursor:] if e.get("ev") == "clip"]


def expect_clip(phone, what, pred, timeout=15):
    return phone.expect(what, lambda e: e.get("ev") == "clip" and pred(e), timeout)


def expect_none(phone, seconds, what):
    time.sleep(seconds)
    got = clips(phone)
    assert not got, what + ": unexpected clip(s) " + str([(c.get("kind"), c.get("text")) for c in got])
    print("  ok:", what, flush=True)


def log_tail(n=12):
    return guest("Get-Content (Join-Path $env:LOCALAPPDATA 'Nearclip\\logs\\nearclip.log') -Tail " + str(n))


def shared_clipboard(mode):
    """Parallels' own clipboard sharing sets the guest clipboard again by itself (it is an echo source too): off while
    the checks run, so that every change comes from the test."""
    subprocess.run(["prlctl", "set", "Windows 11", "--shared-clipboard", mode], capture_output=True)


def main():
    shared_clipboard("off")
    try:
        run()
    finally:
        shared_clipboard("on")


def run():
    print(settings(showToasts=True, autoApply=True, syncImages=True, paused=False, remoteEnabled=False), flush=True)
    launch("--background")
    time.sleep(6)
    state = tempfile.mkdtemp(prefix="nearclip-windows-echo-phone-")
    phone = Peer("swift", shlex.quote(CLI) + " --platform android", "Galaxy S25", state=state)
    phone.send(cmd="ticket")
    uri = phone.expect("ticket", lambda e: e.get("ev") == "ticket")["uri"]
    p = urlsplit(uri)
    q = [(k, HOST if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    launch(urlunsplit((p.scheme, p.netloc, p.path, urlencode(q, quote_via=quote), "")))
    phone.expect("paired", lambda e: e.get("ev") == "paired", 60)
    phone.expect("peer up", lambda e: e.get("ev") == "peer_up", 60)
    print("paired with the Windows app", flush=True)
    time.sleep(3)
    stamp = time.strftime("%H%M%S")

    # 1. The same text again is not a new copy.
    a = "echo A " + stamp
    phone.mark()
    set_text(a)
    expect_clip(phone, "text A", lambda e: e.get("text") == a)
    print("  ok: a copy on Windows arrives", flush=True)
    phone.mark()
    set_text(a)
    guest("Set-Clipboard -Value \"" + a + "`r`n\"")
    expect_none(phone, 4, "the same text set again (and with CRLF) is not sent again")
    b = "echo B " + stamp
    set_text(b)
    expect_clip(phone, "text B", lambda e: e.get("text") == b)
    print("  ok: new text is sent", flush=True)

    # 2. The phone's clip, put back by another sync app, does not go round again.
    c = "인증번호 [482915] " + stamp
    phone.mark()
    phone.send(cmd="send_text", text=c)
    for _ in range(20):
        time.sleep(0.5)
        if guest("Get-Clipboard") == c:
            break
    assert guest("Get-Clipboard") == c, "the phone's clip did not reach the Windows clipboard"
    print("  ok: the phone's clip is on the Windows clipboard", flush=True)
    phone.mark()
    set_text(c)  # Link to Windows putting it back
    expect_none(phone, 4, "the phone's clip put back by another app is not sent back")
    before = seq()
    phone.send(cmd="send_text", text=c)  # the next round of a loop: the same text as a new clip
    time.sleep(4)
    after = seq()
    assert before == after, f"the clipboard was written again ({before} -> {after})"
    print("  ok: the same text from the phone again is not written again (sequence", before, ")", flush=True)

    # 3. A screenshot tool sets one picture twice: bitmap, then PNG. One image goes out.
    phone.mark()
    print(" ", set_bitmap(), flush=True)
    img = expect_clip(phone, "image", lambda e: e.get("kind") == "image", 30)
    print("  ok: the screenshot arrives once:", img.get("size"), "bytes", flush=True)
    phone.mark()
    time.sleep(1.5)
    print(" ", set_png(), flush=True)
    expect_none(phone, 6, "the same picture again as PNG is not sent again")
    print(" ", set_bitmap(x=150), flush=True)
    expect_clip(phone, "another image", lambda e: e.get("kind") == "image", 30)
    print("  ok: a different picture is sent", flush=True)

    # 4. An image from the phone that the clipboard already holds is not written again.
    pic = os.path.join(state, "photo.png")
    subprocess.run(["sips", "-s", "format", "png", "-Z", "900", "/System/Library/Desktop Pictures/Sonoma.heic", "--out", pic],
                   capture_output=True, check=True)
    phone.send(cmd="send_image", path=pic, mime="image/png")
    for _ in range(40):
        time.sleep(0.5)
        if "x" in guest("$i = Get-Clipboard -Format Image; if ($i) { '' + $i.Width + 'x' + $i.Height } else { 'none' }"):
            break
    time.sleep(1.5)
    before = seq()
    phone.send(cmd="send_image", path=pic, mime="image/png")
    time.sleep(5)
    after = seq()
    assert before == after, f"the clipboard was written again ({before} -> {after})"
    print("  ok: the same image from the phone again is not written again (sequence", before, ")", flush=True)

    print("app log:\n" + log_tail(), flush=True)
    phone.quit()
    print("PASS windows echo", flush=True)


if __name__ == "__main__":
    main()
