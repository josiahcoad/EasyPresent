# EasyPresent

A tiny macOS menu-bar tool for presenting: hold a key to drop a **halo** on your cursor,
draw quick **boxes** and **arrows**, and an optional fading **laser** trail — then let go and
it all vanishes. No Dock icon, and **no permissions required** (no Screen Recording, no
Accessibility).

> EasyPresent is a fork of **[07JP27/ZoomacIt](https://github.com/07JP27/ZoomacIt)**,
> reworked from a ZoomIt-style annotation app into a focused presenter pointer.
> Licensed under **GPL-3.0**.

## Install

See **[INSTALL.md](INSTALL.md)** for details. In short:

**Download:** grab the latest `EasyPresent-vX.Y.Z.dmg` from
[Releases](https://github.com/josiahcoad/EasyPresent/releases), drag it to Applications, then
**right-click → Open** once (the build is ad-hoc signed, so Gatekeeper warns the first time).

**Homebrew:**
```bash
brew tap josiahcoad/tap
brew install --cask --no-quarantine easypresent
```

## Usage

Hold **⌥ Option** and the cursor gets a halo + crosshair. While held:

| Gesture | Action |
|---|---|
| **⌥ + move** | Halo cursor (+ laser trail if enabled) |
| **⌥ + drag** | Draw a box |
| **⌥⇧ + drag** | Draw an arrow (tip at the cursor) |
| **⌥Space** | Pin draw mode on / off (stays after you release ⌥) |
| **⌘Z** | Undo the last shape |
| **⌥/** (hold) | Show the help card |
| Release **⌥** / **Esc** | Exit — everything clears |

A guided onboarding runs on first launch (replay it any time from **Settings → General →
Launch Onboarding**), and brief hints appear for your first few sessions.

## Settings

Menu-bar icon → **Settings**:
- **Activation** — choose the hold modifier (Option / Control / Command)
- **Cursor** — halo color, and toggle the trailing laser (off by default)
- **Stats** — local-only counts of sessions / boxes / arrows (never transmitted)

## Build from source

Pure **Swift 6 + AppKit** (SwiftUI only for Settings), macOS 15+, no external dependencies.

```bash
# Debug build + install locally (ad-hoc signed)
xcodebuild -project src/ZoomacIt.xcodeproj -scheme ZoomacIt -configuration Debug \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" build
```

See **[dist/RELEASE.md](dist/RELEASE.md)** for cutting a DMG release and updating the Homebrew tap.

> Note: the internal Xcode target/scheme are still named `ZoomacIt` (from the fork); the
> shipped app and bundle id are `EasyPresent` / `com.josiahcoad.EasyPresent`.

## Credits & License

EasyPresent © 2026 Josiah Coad. Fork of [ZoomacIt](https://github.com/07JP27/ZoomacIt)
© 07JP27. Modified June 2026: replaced the zoom/annotation feature set with a presenter
overlay (halo cursor, laser, boxes/arrows), gesture-based activation, onboarding, and a
no-permissions design.

Licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE). As required
by the GPL, full source (including these modifications) is available in this repository.
