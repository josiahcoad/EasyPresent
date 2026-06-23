# Installing EasyPresent

EasyPresent is a menu-bar presenter overlay (no Dock icon). It needs **no permissions** —
no Screen Recording, no Accessibility. Just install and hold **⌥ Option**.

> Builds are **ad-hoc signed** (not notarized), so macOS Gatekeeper shows a one-time
> "Apple cannot check it for malicious software" warning. Both methods below handle that.

## Option A — Homebrew (recommended)

```bash
brew tap josiahcoad/tap
brew install --cask --no-quarantine easypresent
```

`--no-quarantine` skips the Gatekeeper prompt for this unsigned build. Omit it and you'll
get the right-click-to-open step from Option B instead.

> If Homebrew refuses with *"untrusted tap"* (only when `HOMEBREW_REQUIRE_TAP_TRUST` is set),
> run `brew trust josiahcoad/tap` first.

## Option B — Download the app (.dmg)

1. Download the latest **`EasyPresent-vX.Y.Z.dmg`** from the [Releases page](https://github.com/josiahcoad/EasyPresent/releases).
2. Open the `.dmg` and drag **EasyPresent.app** into **Applications**.
3. First launch (clears the Gatekeeper warning):
   - **Right-click** EasyPresent.app → **Open** → **Open** in the dialog.
   - *or* run once in Terminal: `xattr -cr /Applications/EasyPresent.app`
4. EasyPresent appears in the **menu bar**. Hold **⌥** and move the mouse.

## Using it

| Gesture | Action |
|---|---|
| Hold **⌥** + move | Halo cursor (+ optional laser trail) |
| **⌥ + drag** | Draw a box |
| **⌥⇧ + drag** | Draw an arrow (tip at cursor) |
| **⌥Space** | Toggle draw mode (stays on after releasing ⌥) |

The hold modifier (⌥/⌃/⌘), halo color, and the trailing laser are configurable in
**menu bar icon → Settings**.

---

EasyPresent is a fork of [07JP27/ZoomacIt](https://github.com/07JP27/ZoomacIt),
reworked into a presenter-pointer tool. Licensed under **GPL-3.0**.
