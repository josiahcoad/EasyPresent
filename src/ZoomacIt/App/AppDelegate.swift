import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusBarController: StatusBarController?
    private var hotkeyManager: HotkeyManager { HotkeyManager.shared }
    private var overlayController: OverlayWindowController?
    private var zoomController: StillZoomWindowController?
    private var liveZoomController: LiveZoomWindowController?
    private var breakTimerController: BreakTimerWindowController?
    /// Stores the full-resolution source image when transitioning from Zoom → Draw,
    /// so that Escape from Draw can return to Zoom mode.
    private var zoomSourceForDrawReturn: CGImage?
    private var zoomPanCenterForDrawReturn: CGPoint?
    private var zoomLevelForDrawReturn: CGFloat?
    private var settingsWindowController: SettingsWindowController?

    /// Polls the Option modifier so Draw mode springs up the instant ⌥ is pressed
    /// (halo shows immediately, no mouse movement needed). The spring overlay is
    /// non-activating, so keyboard Option shortcuts (⌥←/→) keep working.
    private var optionPollTimer: Timer?
    /// Previous Option state, so we trigger on the press / release edges only.
    private var wasOptionDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AppDelegate] applicationDidFinishLaunching")

        statusBarController = StatusBarController()
        statusBarController?.onPreferences = { [weak self] in
            self?.showPreferences()
        }
        hotkeyManager.onDrawHotkey = { [weak self] in
            self?.toggleDrawMode()
        }
        hotkeyManager.onDrawToggleHotkey = { [weak self] in
            self?.handleDrawToggleHotkey()
        }
        hotkeyManager.onHelpDown = {
            OnboardingCoordinator.shared.showHelp()
        }
        hotkeyManager.onHelpUp = {
            OnboardingCoordinator.shared.hideHelp()
        }
        hotkeyManager.start()

        startOptionPoll()

        OnboardingCoordinator.shared.startIfFirstRun()
    }

    // MARK: - Option-hold activation

    /// Poll the Option modifier (~33 Hz) and spring-load Draw mode the instant it's
    /// pressed; dismiss it when released (for an unpinned hold). The spring overlay is
    /// non-activating so it never steals keyboard focus.
    private func startOptionPoll() {
        optionPollTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollOption()
            }
        }
    }

    private func pollOption() {
        let down = NSEvent.modifierFlags.contains(Settings.shared.holdModifier.flag)
        defer { wasOptionDown = down }

        if down, !wasOptionDown {
            // Press edge: enter spring Draw mode if nothing else is on screen.
            guard noModeActive else { return }
            presentDrawMode(backgroundImage: nil, springLoaded: true)
        } else if !down, wasOptionDown {
            // Release edge: exit only an unpinned (still spring-loaded) session.
            if let controller = overlayController, controller.isSpringLoaded {
                controller.dismiss()
                overlayController = nil
            }
        }
    }

    /// True when no overlay/zoom mode is currently on screen.
    private var noModeActive: Bool {
        overlayController == nil && zoomController == nil && liveZoomController == nil
    }

    /// ⌥Space: because holding Option already spring-loads Draw mode, this pins the
    /// current hold so it stays after Option is released; pressing it again exits.
    private func handleDrawToggleHotkey() {
        if let controller = overlayController {
            if controller.isSpringLoaded {
                controller.pinOpen()          // pin the active hold → sticky
                OnboardingCoordinator.shared.pinned()
            } else {
                zoomSourceForDrawReturn = nil  // already sticky → toggle off
                controller.dismiss()
                overlayController = nil
            }
            return
        }
        // No mode on screen — enter a sticky Draw session directly.
        presentDrawMode(backgroundImage: nil, springLoaded: false)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Draw Mode

    private func toggleDrawMode(springLoaded: Bool = false) {
        if let zoomController {
            let captured = zoomController.snapshotImageForDrawTransition()
            self.zoomSourceForDrawReturn = zoomController.sourceImage
            // Capture state before dismiss(), since dismiss() triggers onDismiss which nils self.zoomController
            let savedPan = zoomController.panCenter
            let savedZoom = zoomController.zoomLevel
            zoomController.dismiss()
            self.zoomPanCenterForDrawReturn = savedPan
            self.zoomLevelForDrawReturn = savedZoom
            self.zoomController = nil
            presentDrawMode(backgroundImage: captured, springLoaded: springLoaded)
            return
        }

        if let controller = overlayController {
            zoomSourceForDrawReturn = nil  // toggle = full exit, don't return to zoom
            controller.dismiss()
            overlayController = nil
        } else {
            presentDrawMode(backgroundImage: nil, springLoaded: springLoaded)
        }
    }

    private func presentDrawMode(backgroundImage: CGImage?, springLoaded: Bool = false) {
        let controller = OverlayWindowController(
            backgroundImageOverride: backgroundImage,
            springLoaded: springLoaded
        )
        controller.showOverlay()
        overlayController = controller
        OnboardingCoordinator.shared.drawModeEntered()
    }

    /// Called from OverlayWindowController when the user exits draw mode (Escape / right-click)
    func drawModeDidEnd() {
        overlayController = nil
        OnboardingCoordinator.shared.drawModeExited()
        if let savedImage = zoomSourceForDrawReturn {
            zoomSourceForDrawReturn = nil
            restoreZoomMode(withImage: savedImage)
        }
    }

    // MARK: - Still Zoom

    private func toggleStillZoomMode() {
        NSLog("[AppDelegate] toggleStillZoomMode called")
        if let controller = zoomController {
            NSLog("[AppDelegate] Zoom already active — dismissing")
            controller.dismiss()
            zoomController = nil
            return
        }

        if let drawController = overlayController {
            let wasZoomedBeforeDraw = zoomSourceForDrawReturn != nil
            zoomSourceForDrawReturn = nil  // don't restore zoom via drawModeDidEnd
            drawController.dismiss()
            overlayController = nil
            if wasZoomedBeforeDraw {
                NSLog("[AppDelegate] Draw active (from zoom) — toggling zoom off")
                return
            }
            NSLog("[AppDelegate] Draw active (standalone) — dismissing before zoom")
        }

        let controller = StillZoomWindowController()
        setupZoomCallbacks(controller)
        controller.showZoomOverlay()
        zoomController = controller
        NSLog("[AppDelegate] zoomController assigned")
    }

    private func setupZoomCallbacks(_ controller: StillZoomWindowController) {
        controller.onDismiss = { [weak self] in
            NSLog("[AppDelegate] Zoom onDismiss callback")
            self?.zoomController = nil
        }
        controller.onEnterDrawMode = { [weak self] snapshot in
            guard let self else { return }
            NSLog("[AppDelegate] Zoom -> Draw transition")
            // Capture controller and its state before dismiss(), since onDismiss nils self.zoomController
            let zoom = self.zoomController
            self.zoomSourceForDrawReturn = zoom?.sourceImage
            let savedPan = zoom?.panCenter
            let savedZoom = zoom?.zoomLevel
            zoom?.dismiss()
            self.zoomPanCenterForDrawReturn = savedPan
            self.zoomLevelForDrawReturn = savedZoom
            self.zoomController = nil
            self.presentDrawMode(backgroundImage: snapshot)
        }
        controller.onShowFailed = { [weak self] in
            NSLog("[AppDelegate] Zoom show failed (permission denied?)")
            self?.zoomController = nil
        }
    }

    private func restoreZoomMode(withImage source: CGImage) {
        NSLog("[AppDelegate] Restoring zoom mode from Draw")
        let controller = StillZoomWindowController()
        setupZoomCallbacks(controller)
        controller.showZoomOverlay(
            withCapturedImage: source,
            panCenter: zoomPanCenterForDrawReturn,
            zoomLevel: zoomLevelForDrawReturn
        )
        zoomController = controller
        zoomPanCenterForDrawReturn = nil
        zoomLevelForDrawReturn = nil
    }

    // MARK: - Live Zoom

    private func toggleLiveZoomMode() {
        NSLog("[AppDelegate] toggleLiveZoomMode called")
        if let controller = liveZoomController {
            controller.dismiss()
            liveZoomController = nil
            return
        }

        // Dismiss other modes first
        if let drawController = overlayController {
            zoomSourceForDrawReturn = nil  // Don't restore Still Zoom when entering Live Zoom
            drawController.dismiss()
            overlayController = nil
        }
        if let stillZoom = zoomController {
            stillZoom.dismiss()
            zoomController = nil
        }

        let controller = LiveZoomWindowController()
        controller.onDismiss = { [weak self] in
            self?.liveZoomController = nil
        }
        controller.onEnterDrawMode = { [weak self] snapshot in
            guard let self else { return }
            self.liveZoomController?.dismiss()
            self.liveZoomController = nil
            self.presentDrawMode(backgroundImage: snapshot)
        }
        controller.onShowFailed = { [weak self] in
            self?.liveZoomController = nil
        }
        liveZoomController = controller
        controller.showLiveZoom()
    }

    // MARK: - Break Timer

    private func toggleBreakTimer() {
        if let controller = breakTimerController {
            controller.dismiss()
            breakTimerController = nil
        } else {
            let controller = BreakTimerWindowController()
            controller.showTimer()
            breakTimerController = controller
        }
    }

    /// Called from BreakTimerWindowController when the timer is dismissed.
    func breakTimerDidEnd() {
        breakTimerController = nil
    }

    // MARK: - Preferences

    private func showPreferences() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow()
        // Rebuild menu when settings may have changed (hotkey labels)
        statusBarController?.rebuildMenu()
    }
}

// MARK: - Onboarding

/// Small non-activating, click-through panel pinned to the bottom-left that shows the
/// current onboarding step or first-run hint. Never takes focus.
@MainActor
final class HintPanel: NSPanel {
    private let hintView = HintContentView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .init(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = hintView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(text: String) {
        hintView.text = text
        setContentSize(hintView.fittingSize(for: text))
        if let screen = NSScreen.main {
            let margin: CGFloat = 32
            let visible = screen.visibleFrame
            // Bottom-center.
            setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                   y: visible.minY + margin))
        }
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

/// Rounded translucent card with multi-line white text.
private final class HintContentView: NSView {
    var text: String = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let inset: CGFloat = 14
    private static let maxWidth: CGFloat = 360

    private static func attributes() -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        return [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: para]
    }

    func fittingSize(for text: String) -> NSSize {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: Self.maxWidth, height: 2000),
            options: [.usesLineFragmentOrigin],
            attributes: Self.attributes()
        )
        return NSSize(width: ceil(rect.width) + Self.inset * 2,
                      height: ceil(rect.height) + Self.inset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let textRect = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin],
                                attributes: Self.attributes())
    }
}

/// Drives the guided "learn by doing" onboarding and the first-run hints.
@MainActor
final class OnboardingCoordinator {
    static let shared = OnboardingCoordinator()

    private enum Step { case holdToEnter, drawBox, drawArrow, releaseToClear, pin, unpin, tryHelp, done }

    private var step: Step = .done
    private var active = false
    private var inDrawMode = false
    private var isPinned = false
    private var helpVisible = false
    private var showingTimedMessage = false
    private var congratsTimer: Timer?
    private lazy var panel = HintPanel()

    private init() {}

    /// Auto-start the guided flow on first ever launch.
    func startIfFirstRun() {
        if !Settings.shared.onboardingCompleted { start() }
    }

    func start() {
        active = true
        step = .holdToEnter
        refresh()
    }

    /// Replay onboarding (Preferences button).
    func restart() {
        Settings.shared.onboardingCompleted = false
        start()
    }

    // MARK: Events

    func drawModeEntered() {
        inDrawMode = true
        isPinned = false
        if active, step == .holdToEnter { step = .drawBox }
        refresh()
    }

    func recordShape(_ type: ShapeType) {
        if active {
            if step == .drawBox, type == .rectangle { step = .drawArrow }
            else if step == .drawArrow, type == .arrow { step = .releaseToClear }
        }
        refresh()
    }

    func pinned() {
        isPinned = true
        if active, step == .pin { step = .unpin }
        refresh()
    }

    /// Help popover — shown only while ⌥/ is held. During onboarding's final step,
    /// actually showing help is what advances to the congrats.
    func showHelp() { helpVisible = true; refresh() }
    func hideHelp() {
        helpVisible = false
        if active, step == .tryHelp { complete(); return }
        refresh()
    }

    func drawModeExited() {
        let wasPinned = isPinned
        inDrawMode = false
        if active {
            if step == .releaseToClear, !wasPinned { step = .pin }
            else if step == .unpin, wasPinned { step = .tryHelp; isPinned = false; refresh(); return }
        }
        isPinned = false
        refresh()
    }

    private func complete() {
        active = false
        step = .done
        isPinned = false
        helpVisible = false
        Settings.shared.onboardingCompleted = true
        showTimedMessage("Congrats — you know how to use EasyPresent 🎉", duration: 3.5)
    }

    // MARK: Rendering

    /// Show a message that owns the panel for `duration`, ignoring refreshes meanwhile.
    private func showTimedMessage(_ text: String, duration: TimeInterval) {
        showingTimedMessage = true
        panel.show(text: text)
        congratsTimer?.invalidate()
        congratsTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showingTimedMessage = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard !showingTimedMessage else { return }
        if let text = currentText() { panel.show(text: text) } else { panel.hide() }
    }

    private func currentText() -> String? {
        let mod = Settings.shared.holdModifier.symbol
        // Help popover (⌥/ held) takes priority over everything.
        if helpVisible {
            return """
            EasyPresent — controls
            \(mod) + move:  halo
            \(mod) + drag:  box
            \(mod)⇧ + drag:  arrow
            \(mod)Space:  toggle
            """
        }
        if active {
            switch step {
            case .holdToEnter:    return "👋 Hold \(mod) to start drawing"
            case .drawBox:        return "Now drag to draw a box"
            case .drawArrow:      return "Hold ⇧ Shift and drag to draw an arrow"
            case .releaseToClear: return "Let go of \(mod) — your drawing clears"
            case .pin:            return "Hold \(mod) again, then tap Space to keep it on"
            case .unpin:          return "Tap \(mod)Space again to turn it off"
            case .tryHelp:        return "Last thing — press ⌥/ any time to see this help"
            case .done:           return nil
            }
        }
        // First-run ambient hints (after onboarding, only while drawing).
        if inDrawMode, Settings.shared.drawSessions <= 10 {
            var lines = "Drag to draw a box\n⇧ drag for an arrow"
            if !isPinned { lines += "\nTry Space to toggle" }
            return lines
        }
        return nil
    }
}
