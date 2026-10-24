#!/usr/bin/env python3
"""Checks docs/store/microsoft-listing.json against Partner Center's limits.

    python3 docs/store/check-listing.py

Description up to 10,000 characters with a two-line hook, short description up to 270 (Partner Center's field shows
less), 3-20 features of up to 200, up to 7 search terms of up to 30 characters and 21 words in all, one caption per
screenshot (promo/store.sh makes 7) of up to 200, trailer title up to 255, plain text only, and the same set of fields
in every language.
"""
import json
import re
import sys
from pathlib import Path

LISTING = Path(__file__).resolve().parent / "microsoft-listing.json"
SHOTS = 7
MARKUP = re.compile(r"<[A-Za-z/!]|\*\*|^#|\]\(", re.M)


def main() -> int:
    listing = json.loads(LISTING.read_text(encoding="utf-8"))
    problems = []
    fields = None
    for code, item in listing.items():
        def bad(msg):
            problems.append(f"{code}: {msg}")
        n = lambda s: len(s.encode("utf-16-le")) // 2
        if fields is None:
            fields = set(item)
        elif set(item) != fields:
            bad(f"fields differ: {sorted(set(item) ^ fields)}")
        d = item["description"]
        if not 200 <= n(d) <= 10000:
            bad(f"description has {n(d)} characters")
        if d.count("\n", 0, d.find("\n\n")) != 1:
            bad("description should open with a two-line hook followed by a blank line")
        if n(item["shortDescription"]) > 270:
            bad("short description over 270")
        if not 3 <= len(item["features"]) <= 20 or any(n(f) > 200 for f in item["features"]):
            bad("features: 3-20 of up to 200 characters")
        terms = item["searchTerms"]
        if len(terms) > 7 or any(n(t) > 30 for t in terms) or sum(len(t.split()) for t in terms) > 21:
            bad("search terms: up to 7, 30 characters each, 21 words in all")
        if len(item["screenshotCaptions"]) != SHOTS or any(n(c) > 200 for c in item["screenshotCaptions"]):
            bad(f"{SHOTS} screenshot captions of up to 200 characters")
        if n(item["trailerTitle"]) > 255:
            bad("trailer title over 255")
        for k in ("description", "shortDescription", "additionalLicenseTerms"):
            if MARKUP.search(item[k]):
                bad(f"{k} contains markup")
        if "\n" in item["additionalLicenseTerms"]:
            bad("additional license terms must be one line")
    for p in problems:
        print("✗", p)
    print(("FAILED" if problems else "ok") + f" · {len(listing)} languages")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

