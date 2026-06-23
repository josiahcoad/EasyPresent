import AppKit

/// A borderless, transparent panel that sits above all other windows for Draw mode.
///
/// When `nonactivating` is true it uses `.nonactivatingPanel` and refuses key status,
/// so it can show the halo/laser and capture clicks WITHOUT stealing keyboard focus
/// from the foreground app (keeping ⌥←/→ word-jump etc. working while ⌥ is held).
final class OverlayWindow: NSPanel {

    private var keyable = true

    /// Activating overlay covering one screen (used by Still Zoom / Zoom→Draw).
    convenience init(for screen: NSScreen) {
        self.init(contentRect: screen.frame, nonactivating: false)
    }

    /// `contentRect` may span a single display. `nonactivating` controls whether the
    /// panel grabs keyboard focus (false = sticky/zoom-transition; true = spring hold).
    convenience init(contentRect: NSRect, nonactivating: Bool) {
        var style: NSWindow.StyleMask = [.borderless]
        if nonactivating { style.insert(.nonactivatingPanel) }

        self.init(
            contentRect: contentRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        keyable = !nonactivating
    }

    /// Promote a previously non-activating overlay to key-capable (used when a spring
    /// session is pinned, so Esc / ⌘Z work in the dedicated drawing session).
    func enableKey() { keyable = true }

    // MARK: - Overrides

    /// Only an activating (non-spring) overlay may become key; a spring overlay never
    /// takes key status, so keyboard events keep flowing to the foreground app.
    override var canBecomeKey: Bool { keyable }

    override var canBecomeMain: Bool { false }

    /// Keep the overlay exactly where we place it (the full `screen.frame`). AppKit
    /// otherwise shifts/shrinks a borderless panel to keep it out from under the menu
    /// bar, which makes the window smaller than the display — so the halo would lag or
    /// clamp a few cm in from the top/edges while tracking fine near the center.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
