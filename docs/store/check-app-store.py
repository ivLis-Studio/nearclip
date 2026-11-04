#!/usr/bin/env python3
"""Validate Apple listing copy and optionally export files ready for App Store Connect.

This command does not contact Apple or submit an app.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIMITS = {"subtitle": 30, "promotionalText": 170, "keywords": 100,
          "descriptionMac": 4000, "descriptionIOS": 4000}
OTHER_PLATFORMS = re.compile(r"\b(?:android|windows|galaxy|samsung)\b|안드로이드|갤럭시|삼성", re.I)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, default=ROOT / "docs/store/app-store.json")
    parser.add_argument("--export", type=Path, help="Write local files; does not upload them")
    args = parser.parse_args()
    data = json.loads(args.metadata.read_text(encoding="utf-8"))
    errors = []
    name = data["shared"]["name"]
    if not name.strip() or len(name.encode("utf-16-le")) // 2 > 30:
        errors.append("shared.name: empty or longer than 30 UTF-16 units")
    for locale in ("en-US", "ko"):
        for field, limit in LIMITS.items():
            value = data[locale][field]
            count = len(value.encode("utf-16-le")) // 2
            if not value.strip() or count > limit:
                errors.append(f"{locale}.{field}: {count}/{limit}")
            if OTHER_PLATFORMS.search(value):
                errors.append(f"{locale}.{field}: other-platform marketing reference")
            print(f"{locale}.{field}: {count}/{limit}")
    if errors:
        raise SystemExit("\n".join(errors))
    if args.export:
        for platform, description in (("macos", "descriptionMac"), ("ios-ipados", "descriptionIOS")):
            for locale in ("en-US", "ko"):
                target = args.export / platform / locale
                target.mkdir(parents=True, exist_ok=True)
                for field in ("subtitle", "promotionalText", "keywords", description):
                    filename = "description" if field == description else field
                    (target / f"{filename}.txt").write_text(data[locale][field] + "\n", encoding="utf-8")
        args.export.mkdir(parents=True, exist_ok=True)
        (args.export / "review-notes.txt").write_text(data["shared"]["reviewNotes"] + "\n", encoding="utf-8")
        print(f"Exported local copy to {args.export}; no upload or submission performed")
    print("Apple listing copy passed")


if __name__ == "__main__":
    main()
