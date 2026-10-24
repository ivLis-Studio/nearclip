#!/usr/bin/env python3
"""Fill a Partner Center listing export with docs/store/microsoft-listing.json and stage it for "Import folder".

    python3 docs/store/build-listing-csv.py EXPORT.csv [--assets promo/out/store] [--out promo/out/store/import] [--no-trailers]

EXPORT.csv is the file Partner Center gives you from "Export listings" on the submission overview. Export it after the
package is uploaded, so it already has one column per language the package declares (en-us and ko-kr).

The result is OUT/nearclip-listing/: one CSV plus the screenshots, art and trailers it points at (promo/store.sh makes
them). Partner Center wants paths that start with the folder's own name, so that folder is what you pick in
"Import listings > Import folder". Korean gets the Korean screenshots, trailer and thumbnail; English the English ones.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import shutil
import sys
from pathlib import Path

ROOT = "nearclip-listing"
REPO = Path(__file__).resolve().parents[2]
SHOTS = ["01-one-clipboard", "02-mac-to-windows", "03-iphone-to-windows", "04-windows-flyout", "05-pair-with-qr",
         "06-another-network", "07-end-to-end"]
ART = {  # CSV field -> file in <assets>/art (the larger size Partner Center accepts for each slot)
    "StoreLogo720x1080": "PosterArt-1440x2160.png",
    "StoreLogo1080x1080": "BoxArt-2160x2160.png",
    "StoreLogo300x300": "StoreLogo-300x300.png",
    "PromoImage1920x1080": "SuperHeroArt-3840x2160.png",
}


def listing_key(code: str, listing: dict) -> str | None:
    c = code.strip().lower()
    if c in listing:
        return c
    base = c.split("-")[0]
    for key in listing:
        if key.split("-")[0] == base:
            return key
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("export", type=Path, help="CSV from Partner Center > Export listings")
    ap.add_argument("--listing", type=Path, default=REPO / "docs/store/microsoft-listing.json")
    ap.add_argument("--assets", type=Path, default=REPO / "promo/out/store")
    ap.add_argument("--out", type=Path, default=REPO / "promo/out/store/import")
    ap.add_argument("--no-trailers", action="store_true", help="leave the trailers out")
    args = ap.parse_args()

    listing = json.loads(args.listing.read_text(encoding="utf-8"))
    rows = list(csv.reader(io.StringIO(args.export.read_bytes().decode("utf-8-sig"))))
    header, body = rows[0], rows[1:]
    if header[:4] != ["Field", "ID", "Type (Type)", "default"]:
        sys.exit(f"unexpected header {header[:4]} — is this a Partner Center listing export?")
    while header and header[-1] == "":
        header.pop()
    langs = header[4:]
    have = {listing_key(c, listing) for c in langs}
    langs += [k for k in listing if k not in have]
    header = header[:4] + langs
    width = len(header)
    body = [r + [""] * (width - len(r)) if len(r) < width else r[:width] for r in body]

    dest = args.out / ROOT
    dest.mkdir(parents=True, exist_ok=True)
    used: set[str] = set()

    def asset(rel: str) -> str:
        if not (args.assets / rel).is_file():
            sys.exit(f"missing asset {args.assets / rel} (promo/store.sh)")
        used.add(rel)
        return f"{ROOT}/{rel}"

    def values(key: str) -> dict[str, str]:
        item = listing[key]
        lang = "ko" if key == "ko-kr" else "en"
        v = {
            "Description": item["description"],
            "ShortDescription": item["shortDescription"],
            "DevStudio": item["developedBy"],
            "CopyrightTrademarkInformation": item["copyright"],
            "AdditionalLicenseTerms": item["additionalLicenseTerms"],
        }
        if not args.no_trailers:
            v["TrailerTitle1"] = item["trailerTitle"]
            v["Trailer1"] = asset(f"trailer/Nearclip-trailer-{lang}.mp4")
            v["TrailerThumbnail1"] = asset(f"trailer/Nearclip-trailer-{lang}-thumbnail.png")
            v["TrailerToPlayAtTopOfListing"] = v["Trailer1"]
        for field, name in ART.items():
            v[field] = asset(f"art/{name}")
        for i, (name, caption) in enumerate(zip(SHOTS, item["screenshotCaptions"]), 1):
            v[f"DesktopScreenshot{i}"] = asset(f"screenshots/{lang}/{name}.png")
            v[f"DesktopScreenshotCaption{i}"] = caption
        for i, feature in enumerate(item["features"], 1):
            v[f"Feature{i}"] = feature
        for i, term in enumerate(item["searchTerms"], 1):
            v[f"SearchTerm{i}"] = term
        return v

    index = {r[0]: r for r in body if r and r[0]}
    for col, code in enumerate(langs, start=4):
        key = listing_key(code, listing)
        if key is None:
            print(f"! no copy for {code}; its column is left as exported", file=sys.stderr)
            continue
        for field, text in values(key).items():
            if field not in index:
                sys.exit(f"field {field} is not in the export")
            index[field][col] = text
        print(f"{code:<8} <- {key}")

    for rel in sorted(used):
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.assets / rel, target)
    out = io.StringIO(newline="")
    csv.writer(out, lineterminator="\r\n").writerows([header] + body)
    (dest / f"{ROOT}.csv").write_bytes(b"\xef\xbb\xbf" + out.getvalue().encode("utf-8"))
    size = sum((dest / rel).stat().st_size for rel in used)
    print(f"\n{dest}  ({len(used)} assets, {size / 1e6:.0f} MB) — pick this folder in Import listings > Import folder")
    return 0


if __name__ == "__main__":
    sys.exit(main())

