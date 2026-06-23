#!/usr/bin/env bash
#
# Build a release DMG, publish a GitHub release, and bump the Homebrew cask.
#
#   scripts/release.sh <version>      e.g.  scripts/release.sh 0.2.0
#
# Requires: Xcode, gh (authenticated), write access to both repos below.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>  (e.g. 0.2.0)}"
APP_REPO="josiahcoad/EasyPresent"
TAP_REPO="josiahcoad/homebrew-tap"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building Release (ad-hoc signed)…"
xcodebuild -project src/EasyPresent.xcodeproj -scheme EasyPresent -configuration Release \
  -derivedDataPath build-release \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" CODE_SIGN_ENTITLEMENTS="" \
  build >/dev/null

APP="build-release/Build/Products/Release/EasyPresent.app"
[ -d "$APP" ] || { echo "build failed: $APP not found"; exit 1; }

echo "==> Packaging DMG…"
DMG="dist/EasyPresent-v${VERSION}.dmg"
mkdir -p dist
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "EasyPresent" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "    $DMG"
echo "    sha256 $SHA"

echo "==> Creating GitHub release v${VERSION}…"
NOTES="EasyPresent v${VERSION}.

Update: brew update && brew upgrade easypresent  — or download the DMG below (see INSTALL.md)."
gh release create "v${VERSION}" "$DMG" --repo "$APP_REPO" \
  --title "EasyPresent v${VERSION}" --notes "$NOTES"

echo "==> Bumping Homebrew cask in ${TAP_REPO}…"
TAP="$(mktemp -d)"
gh repo clone "$TAP_REPO" "$TAP" -- --quiet
CASK="$TAP/Casks/easypresent.rb"
sed -i '' -E "s/^  version \".*\"/  version \"${VERSION}\"/" "$CASK"
sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" "$CASK"
git -C "$TAP" commit -aqm "easypresent ${VERSION}"
git -C "$TAP" push -q
rm -rf "$TAP"

echo "==> Done. Users update with:  brew update && brew upgrade easypresent"
