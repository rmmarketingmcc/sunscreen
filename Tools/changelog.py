#!/usr/bin/python3
"""Adds a release to the changelog. Called by release.sh.

    Tools/changelog.py add <version> <date>   (notes as "- line" bullets on stdin)

Keeps docs/changelog.json (read by the website and bundled into the app for
"What's new") and CHANGELOG.md (for GitHub) in sync.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JSON = ROOT / "docs" / "changelog.json"
MD = ROOT / "CHANGELOG.md"


def bullets(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if line.startswith(("- ", "* ")):
            line = line[2:]
        if line:
            out.append(line)
    return out


def write_markdown(entries):
    lines = ["# Changelog", "", "Every Sunscreen release. The app shows the newest entry after it updates itself.", ""]
    for e in entries:
        lines.append(f"## {e['version']} ({e['date']})")
        lines += [f"- {n}" for n in e["notes"]]
        lines.append("")
    MD.write_text("\n".join(lines))


def main():
    if len(sys.argv) != 4 or sys.argv[1] != "add":
        sys.exit(__doc__)
    version, date = sys.argv[2], sys.argv[3]
    notes = bullets(sys.stdin.read())
    if not notes:
        sys.exit("No release notes")
    entries = json.loads(JSON.read_text()) if JSON.exists() else []
    entries = [e for e in entries if e["version"] != version]
    entries.insert(0, {"version": version, "date": date, "notes": notes})
    JSON.write_text(json.dumps(entries, indent=2, ensure_ascii=False) + "\n")
    write_markdown(entries)
    print(f"Changelog: {version} with {len(notes)} note(s)")


if __name__ == "__main__":
    main()
