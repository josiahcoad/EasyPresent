# Releasing EasyPresent

## Recommended: tag → CI does the rest

Push a version tag and GitHub Actions (`.github/workflows/release.yml`) builds the app,
packages the DMG, creates the release, and bumps the Homebrew cask:

```bash
git tag v0.3.0 && git push origin v0.3.0
```

**One-time setup for the cask bump (already done):** the repo secret **`TAP_DEPLOY_KEY`** in
`josiahcoad/EasyPresent` holds the private half of an ed25519 **deploy key** registered with
write access on `josiahcoad/homebrew-tap` only (scoped to that one repo — no broad PAT). CI
clones the tap over SSH with that key to bump `version`/`sha256`. Without the secret, CI still
builds + publishes the release and just skips the cask bump. To rotate: generate a new key,
`gh repo deploy-key add key.pub --repo josiahcoad/homebrew-tap --allow-write`, then
`gh secret set TAP_DEPLOY_KEY --repo josiahcoad/EasyPresent < key`.

## Code signing (stable identity for Accessibility)

Click-through and scroll-through need macOS **Accessibility**, which the system ties to the
app's code "designated requirement." Ad-hoc signing changes that requirement on every build,
so the grant would reset on each update. To avoid that, builds sign with a **stable
self-signed cert** named **`EasyPresent Self-Signed`** (no Apple Developer account / $99
needed; it does not silence Gatekeeper, but the cask already strips quarantine).

**One-time local setup:** Keychain Access → *Certificate Assistant → Create a Certificate…*
→ Name `EasyPresent Self-Signed`, Identity Type *Self Signed Root*, Certificate Type
*Code Signing* → Create. After switching from ad-hoc to this cert, grant Accessibility once
more (the requirement changed); it then persists across rebuilds. `make dev`, `release.sh`,
and CI all auto-fall back to ad-hoc if the cert/secret is absent.

**CI setup (so released updates keep the grant):** export the same cert as a `.p12` and add
two repo secrets to `josiahcoad/EasyPresent`:
```bash
# In Keychain Access: right-click "EasyPresent Self-Signed" → Export → .p12 (set a password)
base64 -i EasyPresent-Self-Signed.p12 | gh secret set MACOS_CERT_P12 --repo josiahcoad/EasyPresent
gh secret set MACOS_CERT_PASSWORD --repo josiahcoad/EasyPresent   # paste the .p12 password
```
CI imports it into a temporary keychain and signs the release with it. Use the **same** cert
locally and in CI so every build shares one requirement.

## Local one-liner (fallback)

```bash
make release-dmg VERSION=0.3.0
```
Same chain, run from your Mac (requires `gh` authenticated with write to both repos). The
manual steps below document what both paths do.

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
brew install --cask ./dist/homebrew-tap/Casks/easypresent.rb
```

## Notes
- The `sha256` in the cask **must** match the uploaded DMG exactly — update it every release.
- Replace `josiahcoad` with your actual GitHub username if different.
- The build is ad-hoc signed (not notarized); the cask's `postflight` strips the quarantine
  flag so it opens without a Gatekeeper prompt. Notarizing with an Apple Developer ID would
  remove the need for that workaround entirely.
