import AppKit
import CoreGraphics
import CoreVideo
@preconcurrency import ScreenCaptureKit

/// Manages the lifecycle of the overlay window used for Draw mode.
@MainActor
final class OverlayWindowController {

    /// One overlay window + canvas per display. macOS's "Displays have separate Spaces"
    /// prevents a single window from painting across displays, so we use one per screen.
    private var overlayWindows: [OverlayWindow] = []
    private var canvasViews: [DrawingCanvasView] = []
    private let backgroundImageOverride: CGImage?
    /// When true, Draw mode was entered by holding Option and exits when Option is released.
    private var springLoaded: Bool

    init(backgroundImageOverride: CGImage? = nil, springLoaded: Bool = false) {
        self.backgroundImageOverride = backgroundImageOverride
        self.springLoaded = springLoaded
    }

    /// True while this session would exit on Option release (i.e. an unpinned hold).
    var isSpringLoaded: Bool { springLoaded }

    /// Pin a spring-loaded (hold-Option) session so it stays open after Option is released.
    /// A pinned session is a dedicated drawing session, so we take key focus — that makes
    /// Esc / ⌘Z work (spring/hold mode stays focus-free for ⌥ keyboard shortcuts).
    func pinOpen() {
        springLoaded = false
        canvasViews.forEach { $0.exitsOnOptionRelease = false }
        overlayWindows.forEach { $0.enableKey() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let target = overlayWindows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? overlayWindows.first
        if let window = target {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(window.contentView)
        }
    }

    /// Repaint every canvas after the active draw color changed (⌥↑ / ⌥↓ cycling).
    func refreshColor() {
        canvasViews.forEach { $0.needsDisplay = true }
    }

    // MARK: - Public

    func showOverlay() {
        Settings.shared.drawSessions += 1  // local usage counter
        if let backgroundImageOverride {
            // Zoom → Draw transition: single-screen snapshot as background (activating).
            guard let screen = NSScreen.screenContainingMouse ?? NSScreen.main else { return }
            self.presentOverlay(on: screen, backgroundImage: backgroundImageOverride,
                                nonactivating: false, makeKey: true)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        // Presenter Draw: one transparent overlay per display so the halo/laser follow
        // the cursor across all screens. A spring (hold-Option) session is NON-activating
        // so it never steals keyboard focus; a sticky session activates normally.
        let mouseScreen = NSScreen.screenContainingMouse ?? NSScreen.main
        for screen in NSScreen.screens {
            presentOverlay(on: screen, backgroundImage: nil,
                           nonactivating: springLoaded,
                           makeKey: !springLoaded && screen == mouseScreen)
        }
        if !springLoaded {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    private func presentOverlay(on screen: NSScreen, backgroundImage: CGImage?,
                                nonactivating: Bool, makeKey: Bool) {
        let window = OverlayWindow(contentRect: screen.frame, nonactivating: nonactivating)
        let canvas = DrawingCanvasView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            backgroundImage: backgroundImage
        )
        canvas.exitsOnOptionRelease = springLoaded
        canvas.onDismiss = { [weak self] in
            self?.dismiss()
        }

        window.contentView = canvas
        window.setFrame(screen.frame, display: false)
        if makeKey {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(canvas)
        } else {
            window.orderFrontRegardless()
        }

        overlayWindows.append(window)
        canvasViews.append(canvas)
    }

    func dismiss() {
        guard !overlayWindows.isEmpty else { return }
        for window in overlayWindows {
            window.orderOut(nil)
            window.close()
        }
        overlayWindows.removeAll()
        canvasViews.removeAll()

        // Notify the app delegate
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.drawModeDidEnd()
        }
    }

    // MARK: - Screen Capture

    static func captureScreenImage(
        displayID: CGDirectDisplayID,
        width: CGFloat,
        height: CGFloat,
        scaleFactor: CGFloat
    ) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("[OverlayWindowController] Screen Recording not permitted — using blank background.")
            return nil
        }

        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = availableContent.displays.first(where: { $0.displayID == displayID }) else {
                NSLog("[OverlayWindowController] Display not found.")
                return nil
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(width * scaleFactor)
            config.height = Int(height * scaleFactor)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            NSLog("[OverlayWindowController] Screen capture failed: %@", error.localizedDescription)
            return nil
        }
    }
}
