#!/usr/bin/env python3
"""Android helpers for the final acceptance run (emulator-5584).
  android.py link <ticket-file>        prints the pairing link rewritten for the emulator (h=10.0.2.2)
  android.py tap <text>                taps the first UI element whose text or content-desc equals <text>
  android.py texts                     prints visible texts
"""
import re, subprocess, sys
from urllib.parse import urlsplit, parse_qsl, urlencode, urlunsplit, quote

ADB = ["adb", "-s", "emulator-5584"]

def dump():
    subprocess.run(ADB + ["shell", "uiautomator", "dump", "/sdcard/nc-ui.xml"], capture_output=True)
    return subprocess.run(ADB + ["shell", "cat", "/sdcard/nc-ui.xml"], capture_output=True, text=True).stdout

def nodes(xml):
    for m in re.finditer(r'<node [^>]*>', xml):
        n = m.group(0)
        text = re.search(r' text="([^"]*)"', n).group(1)
        desc = re.search(r' content-desc="([^"]*)"', n).group(1)
        b = re.search(r' bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
        yield text, desc, tuple(map(int, b.groups())) if b else None

cmd = sys.argv[1]
if cmd == "link":
    u = open(sys.argv[2]).read().strip()
    p = urlsplit(u)
    q = [(k, "10.0.2.2" if k == "h" else v) for k, v in parse_qsl(p.query, keep_blank_values=True)]
    print(urlunsplit((p.scheme, p.netloc, p.path, urlencode(q, quote_via=quote), "")))
elif cmd == "tap":
    want = sys.argv[2]
    for text, desc, b in nodes(dump()):
        if b and (text == want or desc == want):
            x, y = (b[0] + b[2]) // 2, (b[1] + b[3]) // 2
            subprocess.run(ADB + ["shell", "input", "tap", str(x), str(y)])
            print(f"tapped {want!r} at {x},{y}")
            break
    else:
        print(f"not found: {want!r}")
        sys.exit(1)
elif cmd == "texts":
    for text, desc, b in nodes(dump()):
        if text or desc:
            print(repr(text or desc))

