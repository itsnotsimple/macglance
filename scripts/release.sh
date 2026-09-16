#!/bin/zsh
# Publishes a new MacGlance version on GitHub Releases, where the app's updater finds it.
# Usage: scripts/release.sh 0.24 "What changed"
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$1
NOTES=${2:-""}
REPO=itsnotsimple/macglance

[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first."; exit 1; }

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
./scripts/build-app.sh
ZIP=build/MacGlance-$VERSION.zip
rm -f $ZIP
ditto -c -k --keepParent build/MacGlance.app $ZIP
swift scripts/sign-update.swift $ZIP > $ZIP.sig   # with the private key in ~/.config/macglance

git commit -qam "Release $VERSION"${CO_AUTHOR:+$'\n\n'"Co-Authored-By: $CO_AUTHOR"}   # CO_AUTHOR: optional trailer
git tag "v$VERSION"
git push -q origin main "v$VERSION"

# The GitHub API, with the token git already keeps in the Keychain (never printed or stored here).
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git credential fill | sed -n 's/^password=//p')
api() { curl -fsS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }
BODY=$(python3 -c 'import json, sys; print(json.dumps({"tag_name": "v" + sys.argv[1], "name": "MacGlance " + sys.argv[1], "body": sys.argv[2]}))' "$VERSION" "$NOTES")
RELEASE_ID=$(api -X POST "https://api.github.com/repos/$REPO/releases" -d "$BODY" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')
for FILE in $ZIP $ZIP.sig; do
    api -X POST -H "Content-Type: application/octet-stream" --data-binary @$FILE \
        "https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$(basename $FILE)" > /dev/null
done
echo "Released MacGlance $VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
