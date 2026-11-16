#!/bin/zsh
# Publica uma release no GitHub com o Snapmark.app compilado.
# Uso: atualize o arquivo VERSION, escreva release-notes/<versão>.md, faça commit e rode ./release.sh
# Versões com sufixo (ex.: 0.1.0-alpha.0) saem como pre-release.
set -e
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
TAG="v$VERSION"
NOTES="release-notes/$VERSION.md"
ZIP="dist/Snapmark-$VERSION.zip"

[[ -f "$NOTES" ]] || { echo "Faltam as notas: $NOTES"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Há mudanças sem commit. Faça commit antes."; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "A tag $TAG já existe."; exit 1; }

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
echo "Release $TAG publicada."
