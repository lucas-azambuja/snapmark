#!/bin/zsh
# Publishes a GitHub release with the built Snapmark.app.
# Usage: update VERSION, write release-notes/<version>.md, commit, then run ./release.sh
# Versions with a suffix (e.g. 0.1.0-alpha.0) are published as pre-releases.
set -e
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
TAG="v$VERSION"
NOTES="release-notes/$VERSION.md"
ZIP="dist/Snapmark-$VERSION.zip"

[[ -f "$NOTES" ]] || { echo "Missing release notes: $NOTES"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "There are uncommitted changes. Commit them first."; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "Tag $TAG already exists."; exit 1; }

./build.sh
rm -rf dist && mkdir -p dist
ditto -c -k --keepParent build/Snapmark.app "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

git tag -a "$TAG" -m "Snapmark $VERSION"
git push origin HEAD "$TAG"

PRE=()
[[ "$VERSION" == *-* ]] && PRE=(--prerelease)
gh release create "$TAG" "$ZIP" "$ZIP.sha256" \
  --title "Snapmark $VERSION" --notes-file "$NOTES" --verify-tag "${PRE[@]}"
echo "Release $TAG published."
