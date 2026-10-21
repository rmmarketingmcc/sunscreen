#!/bin/bash
# Publishes a new Sunscreen version to everyone who has it.
#   ./release.sh 1.4                         notes written from the commits since the last release
#   ./release.sh 1.4 "Fixed the pause key"   or your own notes (one line, or several "- " lines)
# The changelog (CHANGELOG.md, the website and the app's "What's new") updates itself.
# Apps show "Update available" (and a dot on the menu bar icon) within 6 hours, or as
# soon as the panel is opened; one click installs it. Your own Mac updates the same way.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-}"
NOTES="${2:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: ./release.sh <version> [\"what changed\"]   e.g. ./release.sh 1.4"
  exit 1
fi
CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
if [[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" != "$VERSION" || "$CURRENT" == "$VERSION" ]]; then
  echo "Version must be higher than the current $CURRENT"
  exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then echo "v$VERSION already exists"; exit 1; fi

# Automatic notes: the subject line of every commit since the last release (commit subjects are
# written for users), minus release/guide/housekeeping commits.
if [[ -z "$NOTES" ]]; then
  PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)
  NOTES=$(git log --no-merges --pretty='%s' ${PREV:+$PREV..}HEAD | grep -vE '^(Release |Guide:|Changelog|Housekeeping)' || true)
  [[ -n "$NOTES" ]] || { echo "No changes since $PREV, nothing to release"; exit 1; }
fi
NOTES=$(printf '%s\n' "$NOTES" | sed -e '/^[[:space:]]*$/d' -e 's/^[-*] //' -e 's/^/- /')

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Info.plist
printf '%s\n' "$NOTES" | /usr/bin/python3 Tools/changelog.py add "$VERSION" "$(date +%Y-%m-%d)"

./build.sh
git add -A
git commit -q -m "Release $VERSION" -m "$NOTES"
git tag "v$VERSION"
git push -q origin HEAD --tags
gh release create "v$VERSION" build/Sunscreen.zip build/Sunscreen.dmg --title "Sunscreen $VERSION" --notes "$NOTES"
echo "Released $VERSION:"
printf '%s\n' "$NOTES"
