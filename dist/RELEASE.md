# Releasing EasyPresent

## 1. Build the DMG

```bash
xcodebuild -project src/EasyPresent.xcodeproj -scheme EasyPresent -configuration Release \
  -derivedDataPath build-release \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="" build

VERSION=0.1.0
rm -rf /tmp/ep_dmg && mkdir -p /tmp/ep_dmg
cp -R build-release/Build/Products/Release/EasyPresent.app /tmp/ep_dmg/
ln -s /Applications /tmp/ep_dmg/Applications
hdiutil create -volname "EasyPresent" -srcfolder /tmp/ep_dmg -ov -format UDZO \
  "dist/EasyPresent-v${VERSION}.dmg"
shasum -a 256 "dist/EasyPresent-v${VERSION}.dmg"   # -> update the cask sha256
```

## 2. Publish the GitHub Release

1. Tag `v0.1.0` and create a Release on `github.com/josiahcoad/EasyPresent`.
2. Upload `dist/EasyPresent-v0.1.0.dmg` as a release asset.

## 3. Homebrew tap

The tap is a **separate GitHub repo** named **`homebrew-tap`** (so users run
`brew tap josiahcoad/tap`). One-time setup:

```bash
# in a fresh clone of github.com/josiahcoad/homebrew-tap
mkdir -p Casks
cp <this repo>/dist/homebrew-tap/Casks/easypresent.rb Casks/
git add Casks/easypresent.rb && git commit -m "easypresent 0.1.0" && git push
```

Each new version: rebuild the DMG, upload to the Release, then bump `version` +
`sha256` in `Casks/easypresent.rb` and push the tap.

Verify locally before pushing:

```bash
brew install --cask --no-quarantine ./dist/homebrew-tap/Casks/easypresent.rb
```

## Notes
- The `sha256` in the cask **must** match the uploaded DMG exactly — update it every release.
- Replace `josiahcoad` with your actual GitHub username if different.
- `--no-quarantine` is needed because the build is ad-hoc signed (not notarized). To drop
  that requirement, notarize with an Apple Developer ID and the warning disappears entirely.
