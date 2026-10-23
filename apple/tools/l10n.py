#!/usr/bin/env python3
"""String Catalog helper for the Apple apps.

  python3 apple/tools/l10n.py sync       # pull keys from the last mac + iOS builds into Shared/Localizable.xcstrings
  python3 apple/tools/l10n.py missing    # list keys without a Korean translation
  python3 apple/tools/l10n.py apply      # write translations from apple/tools/ko.json into the catalog
"""
import glob, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
APPLE = os.path.dirname(HERE)
CATALOG = os.path.join(APPLE, "Shared", "Localizable.xcstrings")
KO = os.path.join(HERE, "ko.json")

def stringsdata():
    base = os.path.join(APPLE, "build/dd/Build/Intermediates.noindex/Nearclip.build")
    files = glob.glob(base + "/Debug/Nearclip.build/Objects-normal/arm64/*.stringsdata")
    files += glob.glob(base + "/Debug-iphonesimulator/NearclipiOS.build/Objects-normal/arm64/*.stringsdata")
    return files

def sync():
    files = stringsdata()
    if not files:
        sys.exit("build the mac and iOS targets first")
    subprocess.run(["xcrun", "xcstringstool", "sync", CATALOG, "--stringsdata", *files], check=True)
    cat = json.load(open(CATALOG))
    print(len(cat["strings"]), "keys")

def missing():
    cat = json.load(open(CATALOG))
    ko = json.load(open(KO)) if os.path.exists(KO) else {}
    out = [k for k, v in cat["strings"].items() if k and k not in ko and v.get("extractionState") != "stale" and v.get("shouldTranslate", True)]
    print(json.dumps(out, ensure_ascii=False, indent=1))

def apply():
    cat = json.load(open(CATALOG))
    ko = json.load(open(KO))
    n = 0
    for key, entry in cat["strings"].items():
        if key in ko:
            entry.setdefault("localizations", {})["ko"] = {"stringUnit": {"state": "translated", "value": ko[key]}}
            n += 1
    # Drop keys that no longer exist in code.
    cat["strings"] = {k: v for k, v in cat["strings"].items() if v.get("extractionState") != "stale"}
    with open(CATALOG, "w") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"applied {n} Korean strings; {len(cat['strings']) - n} keys without Korean")

if __name__ == "__main__":
    {"sync": sync, "missing": missing, "apply": apply}[sys.argv[1]]()

