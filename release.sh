#!/bin/bash
# Publishes a new Sunscreen version to everyone who has it.
#   ./release.sh 1.3 "Fixed the pause shortcut"
# Their app shows "Update available" (and a dot on the menu bar icon) within
# 6 hours, or as soon as they open the panel; one click installs it.
# Your own Mac updates the same way, so you see exactly what friends see.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-}"
NOTES="${2:-}"
if [[ -z "$VERSION" || -z "$NOTES" ]]; then
  echo "Usage: ./release.sh <version> \"what changed\"   e.g. ./release.sh 1.3 \"Fixed the pause shortcut\""
  exit 1
fi
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
if [[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" != "$VERSION" || "$CURRENT" == "$VERSION" ]]; then
  echo "Version must be higher than the current $CURRENT"
  exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then echo "v$VERSION already exists"; exit 1; fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist

./build.sh
git add -A
git commit -q -m "Release $VERSION: $NOTES"
git tag "v$VERSION"
git push -q origin HEAD --tags
gh release create "v$VERSION" build/Sunscreen.zip build/Sunscreen.dmg --title "Sunscreen $VERSION" --notes "$NOTES"
echo "Released $VERSION. Apps pick it up within 6 hours, or right away when the panel is opened."
