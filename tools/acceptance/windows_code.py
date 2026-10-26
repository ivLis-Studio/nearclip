#!/usr/bin/env python3
"""Windows: a verification code from a phone is offered, never pasted on its own (PROTOCOL.md §6.7), in the Parallels
"Windows 11" VM.

Needs the Debug build of the app in the guest (windows/NOTES.md). Pairs the app with a Mac CLI peer playing an iPhone
("준서의 iPhone"), then checks:
  1. the phone sends a code (otp): the clipboard is not written, and the toast asks "Copy it?" with Copy and Not now;
  2. Copy (pressed through UI Automation) puts the code on the clipboard;
  3. another code, Not now: the toast goes, and the clipboard keeps the first code;
  4. with arrival notices turned off, a code still shows its toast;
  5. an ordinary clip from the phone is still copied on its own.

  python3 tools/acceptance/windows_code.py [--shots DIR]
"""
import argparse, os, shlex, sys, tempfile, time
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit, quote

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from tools.acceptance.windows_remote import guest, launch, shot, HOST, CLI
from tools.acceptance.windows_transfer import settings
from tools.acceptance.windows_echo import guest_sta, seq, shared_clipboard, log_tail
from tools.interop.run import Peer

# The app's buttons and texts through UI Automation. Buttons are found by their x:Name (the AutomationId); Korean
# texts carry U+2060 WORD JOINERs between syllables (Loc.KeepAll), which are dropped before comparing.
UIA = """
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$p = Get-Process Nearclip -ErrorAction Stop | Select-Object -First 1
$mine = New-Object System.Windows.Automation.PropertyCondition($A::ProcessIdProperty, $p.Id)
function Find($id) {
  $c = New-Object System.Windows.Automation.AndCondition($mine,
    (New-Object System.Windows.Automation.PropertyCondition($A::AutomationIdProperty, $id)))
  for ($i = 0; $i -lt 24; $i++) {
    $e = $A::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
    if ($e) { return $e }
    Start-Sleep -Milliseconds 250
  }
  return $null
}
"""
JOINER = "\u2060"


def press(automation_id):
    """Invokes a button of Nearclip's windows by its AutomationId."""
    return guest_sta(UIA + f"""
$b = Find '{automation_id}'
if (-not $b) {{ 'no button {automation_id}' }} else {{ $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); 'pressed ' + $b.Current.Name }}
""", timeout=90).splitlines()[-1].replace(JOINER, "")


def texts():
    """Every text Nearclip's windows show (the toast's title among them), without word joiners."""
    return guest_sta(UIA + """
$all = $A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $mine)
foreach ($e in $all) { if ($e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and $e.Current.Name) { $e.Current.Name } }
""", timeout=90).replace(JOINER, "")


def code_toast(code):
    """The toast's title, if a code toast for this code is up (the code reads digit by digit: "4 8 2 9 1 5")."""
    for _ in range(20):
        shown = texts().splitlines()
        if code in (t.replace(" ", "") for t in shown):
            return next((t for t in shown if "인증번호" in t or "verification code" in t), "")
        time.sleep(0.5)
    return None


def clipboard():
    return guest("Get-Clipboard")


def run(shots):
    print(settings(showToasts=True, autoApply=True, syncImages=True, paused=False, remoteEnabled=False), flush=True)
    launch("--background")
    time.sleep(6)
    state = tempfile.mkdtemp(prefix="nearclip-windows-code-phone-")
    phone = Peer("swift", shlex.quote(CLI) + " --platform ios", "준서의 iPhone", state=state)
    phone.send(cmd="ticket")
    uri = phone.expect("ticket", lambda e: e.get("ev") == "ticket")["uri"]
    p = urlsplit(uri)
    q = [(k, HOST if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    launch(urlunsplit((p.scheme, p.netloc, p.path, urlencode(q, quote_via=quote), "")))
    phone.expect("paired", lambda e: e.get("ev") == "paired", 60)
    phone.expect("peer up", lambda e: e.get("ev") == "peer_up", 60)
    print("paired with the Windows app", flush=True)
    time.sleep(3)
    guest("Set-Clipboard -Value 'before the code'")

    # 1. A code is offered, not pasted.
    before = seq()
    phone.send(cmd="send_text", text="482915", otp=True)
    title = code_toast("482915")
    assert title is not None, "no code toast"
    print("  ok: the toast asks:", title, flush=True)
    shot(shots, "windows-code-toast")
    after = seq()
    assert before == after and clipboard() == "before the code", f"the code went to the clipboard on its own ({before} -> {after})"
    print("  ok: the clipboard was not written", flush=True)

    # 2. Copy puts it on the clipboard.
    print("  ", press("CopyButton"), flush=True)
    for _ in range(20):
        if clipboard() == "482915":
            break
        time.sleep(0.25)
    assert clipboard() == "482915", "Copy did not copy the code: " + clipboard()
    print("  ok: Copy put the code on the clipboard", flush=True)
    time.sleep(0.4)
    shot(shots, "windows-code-copied")

    # 3. Another code, Not now: the clipboard keeps the first one.
    time.sleep(2.5)
    phone.send(cmd="send_text", text="7712", otp=True)
    assert code_toast("7712") is not None, "no toast for the second code"
    print("  ", press("NotNowButton"), flush=True)
    time.sleep(1.5)
    assert "7712" not in (t.replace(" ", "") for t in texts().splitlines()), "the toast stayed after Not now"
    assert clipboard() == "482915", "Not now changed the clipboard: " + clipboard()
    print("  ok: Not now closed the toast and left the clipboard alone", flush=True)

    # 4. Arrival notices off: a code still asks.
    print(settings(showToasts=False), flush=True)
    phone.mark()
    launch("--background")
    phone.expect("peer up again", lambda e: e.get("ev") == "peer_up", 60)
    time.sleep(3)
    phone.send(cmd="send_text", text="135790", otp=True)
    assert code_toast("135790") is not None, "no code toast with arrival notices off"
    print("  ok: the code toast shows with arrival notices off", flush=True)
    press("NotNowButton")

    # 5. An ordinary clip is still copied on its own.
    plain = "plain text " + time.strftime("%H%M%S")
    phone.send(cmd="send_text", text=plain)
    for _ in range(20):
        if clipboard() == plain:
            break
        time.sleep(0.5)
    assert clipboard() == plain, "an ordinary clip was not copied: " + clipboard()
    print("  ok: an ordinary clip is still copied on its own", flush=True)

    print(settings(showToasts=True), flush=True)
    launch("--background")
    print("app log:\n" + log_tail(8), flush=True)
    phone.quit()
    print("PASS windows code", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", default=tempfile.mkdtemp(prefix="nearclip-windows-code-"))
    args = ap.parse_args()
    shared_clipboard("off")
    try:
        run(args.shots)
    finally:
        shared_clipboard("on")
    print("shots:", args.shots)


if __name__ == "__main__":
    main()

