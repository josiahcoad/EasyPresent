import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// The main NSView subclass that implements the 3-layer compositing architecture
/// for Draw mode rendering.
///
/// Layer stack (bottom to top):
///   1. `finishedLayer` (CGImage)  — all confirmed strokes rasterized
///   2. `previewLayer`  (NSBezierPath) — shape preview during drag
///   3. `activeFreehand` (NSBezierPath) — freehand path during drag
final class DrawingCanvasView: NSView {

    // MARK: - Callbacks

    /// Called when the user exits draw mode (Escape / Option release).
    var onDismiss: (() -> Void)?

    // MARK: - State

    let drawingState = DrawingState()
    private let strokeManager = StrokeManager()

    /// Background image for Draw mode.
    /// - `nil` in live draw mode (transparent canvas, desktop shows through)
    /// - Set when entering via Zoom→Draw transition (frozen zoomed snapshot)
    private var backgroundImage: CGImage?

    // MARK: - 3-Layer Architecture

    /// Confirmed strokes rasterized into a single bitmap.
    private var finishedLayer: CGImage?

    /// Shape preview path during drag (line/rect/ellipse/arrow).
    private var previewLayer: NSBezierPath?

    /// Freehand path being drawn.
    private var activeFreehand: NSBezierPath?

    /// Live spotlight rectangle preview while the user is dragging.
    /// `nil` outside of an active spotlight drag.
    private var spotlightDragRect: CGRect?

    // MARK: - Drag State

    private var dragOrigin: CGPoint = .zero
    private var freehandPoints: [CGPoint] = []
    private var isDragging: Bool = false

    // MARK: - Presenter Mode

    /// When true (Draw mode was entered by holding Option), it exits the moment
    /// Option is released. False for the sticky ⌥Space toggle.
    var exitsOnOptionRelease: Bool = false

    /// Latest cursor position in view coordinates — drives the halo ring.
    private var cursorPoint: CGPoint = .zero

    /// Whether the cursor is currently over THIS display's overlay. With one overlay
    /// per screen, only the canvas under the cursor paints the halo/laser.
    private var cursorInside = false

    /// Whether the halo (and hidden system cursor) is active. Decoupled from mouse capture:
    /// in a pinned session the halo stays on as a presenter pointer even while the window is
    /// transparent to the mouse (so clicks/scroll still pass through). While off we draw no
    /// halo and leave the system cursor visible.
    private var haloActive = false

    // MARK: - Laser Pointer (transient cursor trail)

    /// A single sample of the laser trail with the time it was recorded.
    private struct LaserPoint {
        let location: CGPoint
        let time: TimeInterval
    }

    /// Recent cursor samples that make up the fading laser trail. Never composited
    /// into `finishedLayer` — purely transient, like a real laser pointer.
    private var laserTrail: [LaserPoint] = []

    /// Repaint timer that ages out trail points while the trail is non-empty.
    private var laserTimer: Timer?

    /// Wall-clock time the overlay appeared. Laser samples captured during a short
    /// grace window after this are dropped so the trail doesn't "slide in" from the
    /// cursor's pre-toggle path on activation.
    private var appearTime: TimeInterval = 0

    /// Grace period after appearance during which mouseMoved samples don't feed the laser.
    private static let laserStartupGrace: TimeInterval = 0.25

    // MARK: - Click Pulse

    private struct ClickPulse {
        let origin: CGPoint
        let startTime: TimeInterval
        let color: NSColor
    }

    private var clickPulses: [ClickPulse] = []
    private var pulseTimer: Timer?
    private static let pulseDuration: TimeInterval = 0.45

    /// Pins the halo to the live cursor by re-reading the global mouse location every
    /// tick and converting through the window. This is self-correcting: it stays exact
    /// even if the overlay window is repositioned after it appears (which otherwise made
    /// the halo "slide out" near screen edges) or the cursor crosses displays.
    private var cursorTrackTimer: Timer?

    /// Observes clicks that land on *other* apps (i.e. while the overlay is transparent in
    /// pinned mode) so the halo still does its click "compress" there. Global monitors only
    /// see other-app events, so this never double-fires with the local mouseDown/Up handlers
    /// used while drawing — and mouse-event monitors need no permission.
    private var clickMonitor: Any?

    /// Tracking area so `mouseMoved` fires across the whole view (no button down).
    private var mouseTrackingArea: NSTrackingArea?

    /// How long (seconds) a trail point takes to fully fade out.
    private static let laserFadeDuration: TimeInterval = 0.5

    // MARK: - Click Feedback (halo "compress")

    /// Size multiplier for the halo + crosshair. Rests at 1.0 and eases toward
    /// `haloScaleTarget`: while the mouse button is held the target is `haloPressScale`
    /// (compressed), and on release it returns to 1.0 — a tactile press-and-hold feel.
    private var haloScale: CGFloat = 1.0
    private var haloScaleTarget: CGFloat = 1.0
    private var haloPressTimer: Timer?

    /// How small the halo gets while the button is held, and the per-tick easing factor
    /// of the approach toward the target (higher = snappier).
    private static let haloPressScale: CGFloat = 0.78
    private static let haloScaleEasing: CGFloat = 0.30

    // MARK: - Auto-disappearing shapes

    /// A drawn shape that fades out on its own after `life` seconds (used when the
    /// "auto-disappear" setting is on, instead of compositing into `finishedLayer`).
    private struct TimedShape {
        let path: CGPath
        let color: NSColor
        let penWidth: CGFloat
        let drawnAt: TimeInterval
        let life: TimeInterval
    }
    private var timedShapes: [TimedShape] = []

    /// A snapshot of previously-permanent strokes (the whole `finishedLayer`) that now fades
    /// as one unit — created when the user sets an auto-disappear timeout while shapes are
    /// already on screen.
    private struct TimedLayer {
        let image: CGImage
        let drawnAt: TimeInterval
        let life: TimeInterval
    }
    private var timedLayers: [TimedLayer] = []
    private var autoDisappearTimer: Timer?

    // MARK: - Text Mode

    private var textInputController: TextInputController?

    // MARK: - Init

    init(frame: NSRect, backgroundImage: CGImage?) {
        self.backgroundImage = backgroundImage
        super.init(frame: frame)
        wantsLayer = false  // Use draw(_:) based rendering, not layer-backed
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        let cursor: NSCursor
        switch drawingState.activeTool {
        case .spotlight:
            cursor = Self.spotlightCursor
        default:
            let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let shapeType = drawingState.currentShapeType(modifiers: mods)
            cursor = shapeType == .freehand ? penCursor() : crosshairCursor()
        }
        addCursorRect(bounds, cursor: cursor)
    }

    /// Generates a circular cursor matching the current pen colour and width (freehand mode).
    private func penCursor() -> NSCursor {
        let penWidth = drawingState.penWidth
        let color = drawingState.currentNSColor
        let size = max(penWidth * 2, 8)
        let imageSize = NSSize(width: size + 4, height: size + 4)

        let image = NSImage(size: imageSize, flipped: false) { _ in
            let rect = NSRect(x: 2, y: 2, width: size, height: size)
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            let border = NSBezierPath(ovalIn: rect)
            border.lineWidth = 0.5
            border.stroke()
            return true
        }

        let hotSpot = NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    /// Generates a crosshair cursor scaled by pen width (shape modes).
    private func crosshairCursor() -> NSCursor {
        let penWidth = drawingState.penWidth
        let color = drawingState.currentNSColor
        let armLength = min(max(penWidth * 1.5, 8), 40)
        let thickness = min(max(penWidth, 1), 10)
        let size = armLength * 2 + thickness + 6
        let center = size / 2

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            // Outer contrast stroke (black)
            NSColor.black.withAlphaComponent(0.4).setStroke()
            let outerH = NSBezierPath()
            outerH.move(to: NSPoint(x: center - armLength, y: center))
            outerH.line(to: NSPoint(x: center + armLength, y: center))
            outerH.lineWidth = thickness + 2
            outerH.lineCapStyle = .round
            outerH.stroke()

            let outerV = NSBezierPath()
            outerV.move(to: NSPoint(x: center, y: center - armLength))
            outerV.line(to: NSPoint(x: center, y: center + armLength))
            outerV.lineWidth = thickness + 2
            outerV.lineCapStyle = .round
            outerV.stroke()

            // Inner colored stroke
            color.setStroke()
            let innerH = NSBezierPath()
            innerH.move(to: NSPoint(x: center - armLength, y: center))
            innerH.line(to: NSPoint(x: center + armLength, y: center))
            innerH.lineWidth = thickness
            innerH.lineCapStyle = .round
            innerH.stroke()

            let innerV = NSBezierPath()
            innerV.move(to: NSPoint(x: center, y: center - armLength))
            innerV.line(to: NSPoint(x: center, y: center + armLength))
            innerV.lineWidth = thickness
            innerV.lineCapStyle = .round
            innerV.stroke()

            return true
        }

        return NSCursor(image: image, hotSpot: NSPoint(x: center, y: center))
    }

    /// Minimum width and height (points) for a spotlight rectangle to be confirmed
    /// on mouseUp. Drags smaller than this are treated as accidental clicks /
    /// micro-drags and discarded — chosen above AppKit's ~3pt drag threshold so
    /// the gesture has to be visibly intentional.
    private static let spotlightMinSize: CGFloat = 10

    /// Custom cursor used while the spotlight tool is armed.
    /// Reuses the system crosshair image and overlays a small dashed-rectangle
    /// badge in the lower-right corner so it reads as "drag a rectangle".
    private static let spotlightCursor: NSCursor = {
        let baseCursor = NSCursor.crosshair
        let baseImage = baseCursor.image
        let baseSize = baseImage.size
        let baseHotspot = baseCursor.hotSpot

        // The system crosshair image has a lot of transparent padding around the
        // visible cross. We overlap the badge into that padding so it sits close
        // to the bottom-right arm of the cross instead of floating away from it.
        let badgeWidth: CGFloat = 9
        let badgeHeight: CGFloat = 6
        let badgeOverlap: CGFloat = 6  // how far the badge intrudes into the base image
        let canvasSize = NSSize(
            width: baseSize.width + badgeWidth - badgeOverlap,
            height: baseSize.height + badgeHeight - badgeOverlap
        )

        let composed = NSImage(size: canvasSize, flipped: false) { _ in
            // Draw the system crosshair anchored to the top-left.
            // Image coordinates are bottom-up, so the crosshair's bottom edge
            // sits at y = (canvasSize.height - baseSize.height).
            let baseOrigin = NSPoint(x: 0, y: canvasSize.height - baseSize.height)
            baseImage.draw(at: baseOrigin, from: .zero, operation: .sourceOver, fraction: 1.0)

            // Badge in the bottom-right, partially overlapping the crosshair's padding.
            let badgeRect = NSRect(
                x: canvasSize.width - badgeWidth - 0.5,
                y: 0.5,
                width: badgeWidth,
                height: badgeHeight
            )

            // Outline for visibility on any background.
            NSColor.black.setStroke()
            let outline = NSBezierPath(rect: badgeRect)
            outline.lineWidth = 1.5
            outline.stroke()

            // Dashed white rectangle on top — reads as a "selection / spotlight" hint.
            NSColor.white.setStroke()
            let dashed = NSBezierPath(rect: badgeRect)
            dashed.lineWidth = 1
            dashed.setLineDash([1.5, 1.5], count: 2, phase: 0)
            dashed.stroke()

            return true
        }

        // Hot spot is measured from the top-left in NSCursor, so the x is unchanged
        // and the y matches the system crosshair's hot spot directly (we placed the
        // base image flush with the top of the padded canvas).
        return NSCursor(image: composed, hotSpot: baseHotspot)
    }()

    /// Refresh the cursor after the active tool changes.
    private func updateCursorForTool() {
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Tracking Area

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = mouseTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // The cursor is hidden + halo shown only while interactive (see setHaloActive). Start
        // tracking now so the halo is correctly placed the instant we become interactive. A
        // one-shot seed isn't enough: AppKit can reposition the window just after it appears.
        appearTime = ProcessInfo.processInfo.systemUptime
        laserTrail.removeAll()
        syncCursorToGlobalMouse()
        startCursorTrackingIfNeeded()
        startClickMonitorIfNeeded()
    }

    /// Mirror the click feedback for clicks that pass through to the app below (pinned mode):
    /// halo compress + (if enabled) the expanding ring pulse, at the current cursor point.
    private func startClickMonitorIfNeeded() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.haloActive else { return }
                if Settings.shared.clickPulseEnabled {
                    self.setHaloScaleTarget(event.type == .leftMouseDown ? Self.haloPressScale : 1.0)
                    if event.type == .leftMouseDown {
                        self.spawnClickPulseIfEnabled(at: self.cursorPoint)
                    }
                }
            }
        }
    }

    /// Show/hide the halo (and hide/restore the system cursor with it). Independent of mouse
    /// capture: a pinned session keeps this on so the halo remains a visible pointer even
    /// while the window passes clicks/scroll through. `OverlayWindow.setInteractive` handles
    /// the actual mouse-capture toggle.
    func setHaloActive(_ active: Bool) {
        guard active != haloActive else { return }
        haloActive = active
        if active {
            syncCursorToGlobalMouse()
        } else {
            isDragging = false
            previewLayer = nil
            laserTrail.removeAll()
        }
        needsDisplay = true
    }

    /// Read the current global mouse position and convert it into this view's coordinates.
    private func syncCursorToGlobalMouse() {
        guard let window else { return }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let inside = bounds.contains(local)
        if local != cursorPoint || inside != cursorInside {
            cursorPoint = local
            cursorInside = inside
            needsDisplay = true
        }
    }

    /// ~120 Hz timer that keeps the halo glued to the cursor for as long as the overlay is up.
    private func startCursorTrackingIfNeeded() {
        guard cursorTrackTimer == nil else { return }
        cursorTrackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncCursorToGlobalMouse()
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            laserTimer?.invalidate()
            laserTimer = nil
            cursorTrackTimer?.invalidate()
            cursorTrackTimer = nil
            pulseTimer?.invalidate()
            pulseTimer = nil
            clickPulses.removeAll()
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            haloPressTimer?.invalidate()
            haloPressTimer = nil
            haloScale = 1.0
            haloScaleTarget = 1.0
            autoDisappearTimer?.invalidate()
            autoDisappearTimer = nil
            timedShapes.removeAll()
            timedLayers.removeAll()
            laserTrail.removeAll()
            haloActive = false
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // 1. Draw background (captured screen or whiteboard/blackboard)
        drawBackground(in: context)

        // 1.5 Spotlight mask — drawn between background and strokes so that
        // strokes (finished, preview, freehand) always sit on top of the dim layer.
        if let dragRect = spotlightDragRect {
            drawSpotlightMask(rect: dragRect, in: context)
        } else if let confirmedRect = drawingState.spotlightRect {
            drawSpotlightMask(rect: confirmedRect, in: context)
        }

        // 2. Draw finishedLayer (all confirmed strokes)
        if let finished = finishedLayer {
            context.draw(finished, in: bounds)
        }

        // 2.5 Auto-disappearing content (fades out + removes itself on a timer): first the
        // snapshot of formerly-permanent strokes, then individually-timed shapes on top.
        drawTimedLayers(in: context)
        drawTimedShapes(in: context)

        // 3. Draw previewLayer (shape being dragged)
        if let preview = previewLayer {
            drawingState.currentNSColor.setStroke()
            if drawingState.isHighlighterMode {
                HighlighterRenderer.applyHighlighterStyle(to: preview, penWidth: drawingState.penWidth)
                // .multiply is invisible on transparent pixels; use .normal when no background image
                let blendMode: CGBlendMode = (backgroundImage != nil) ? .multiply : .normal
                NSGraphicsContext.current?.cgContext.setBlendMode(blendMode)
            } else {
                preview.lineWidth = drawingState.penWidth
                preview.lineCapStyle = .round
                preview.lineJoinStyle = .round
            }
            preview.stroke()
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        }

        // 4. Draw activeFreehand (freehand path being drawn)
        if let freehand = activeFreehand {
            drawingState.currentNSColor.setStroke()
            if drawingState.isHighlighterMode {
                HighlighterRenderer.applyHighlighterStyle(to: freehand, penWidth: drawingState.penWidth)
                let blendMode: CGBlendMode = (backgroundImage != nil) ? .multiply : .normal
                NSGraphicsContext.current?.cgContext.setBlendMode(blendMode)
            } else {
                freehand.lineWidth = drawingState.penWidth
                freehand.lineCapStyle = .round
                freehand.lineJoinStyle = .round
            }
            freehand.stroke()
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
        }

        // 5. Halo + laser trail — only while the halo is active and the cursor
        // is over this display. In a pinned session the halo stays on (a persistent pointer)
        // even while the window passes clicks/scroll through.
        if cursorInside && haloActive {
            drawHalo(in: context)
            drawLaserTrail(in: context)
        }

        // 6. Click pulses — drawn regardless of cursor location so the ring still
        // animates if the user keeps moving after clicking.
        drawClickPulses(in: context)
    }

    /// A glowing customizable ring centered on the cursor so the audience can follow the
    /// pointer. `haloScale` (1.0 at rest, ~0.62 while pressing) gives press feedback.
    private func drawHalo(in context: CGContext) {
        Self.drawHalo(
            in: context,
            at: cursorPoint,
            color: Settings.shared.resolvedNSColor,
            radius: Settings.shared.haloSize * haloScale,
            outerRingEnabled: Settings.shared.haloOuterRingEnabled,
            centerStyle: Settings.shared.haloCenterStyle,
            contrastEnabled: Settings.shared.haloContrastEnabled,
            glowEnabled: Settings.shared.haloGlowEnabled,
            infillStyle: Settings.shared.haloInfillStyle
        )
    }

    /// Stateless infill painter: solid soft alpha disk, a thick light-alpha
    /// band hugging the inner edge of the ring, or nothing at all.
    static func drawHaloInfill(
        in context: CGContext,
        rect: CGRect,
        radius: CGFloat,
        color: NSColor,
        style: HaloInfillStyle
    ) {
        switch style {
        case .filled:
            context.setFillColor(color.withAlphaComponent(0.18).cgColor)
            context.fillEllipse(in: rect)
        case .border:
            let bandWidth = max(2, radius * 0.225)
            let inset = bandWidth / 2
            context.saveGState()
            context.setStrokeColor(color.withAlphaComponent(0.25).cgColor)
            context.setLineWidth(bandWidth)
            context.strokeEllipse(in: rect.insetBy(dx: inset, dy: inset))
            context.restoreGState()
        case .none:
            break
        }
    }

    /// Stateless halo renderer shared by the live overlay and the Settings preview.
    static func drawHalo(
        in context: CGContext,
        at point: CGPoint,
        color: NSColor,
        radius: CGFloat,
        outerRingEnabled: Bool,
        centerStyle: HaloCenterStyle,
        contrastEnabled: Bool,
        glowEnabled: Bool,
        infillStyle: HaloInfillStyle
    ) {
        context.saveGState()

        let rect = CGRect(x: point.x - radius, y: point.y - radius,
                          width: radius * 2, height: radius * 2)

        Self.drawHaloInfill(in: context, rect: rect, radius: radius,
                            color: color, style: infillStyle)

        if outerRingEnabled {
            // Outer glow — a tighter, brighter halo hugging the ring. Two stroked
            // passes through a shadow stack each other up so it reads as a real
            // light bloom rather than a diffuse haze.
            if glowEnabled {
                context.saveGState()
                let glowBlur = max(5, radius * 0.5)
                context.setShadow(offset: .zero, blur: glowBlur,
                                  color: color.withAlphaComponent(0.8).cgColor)
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(2.5)
                context.strokeEllipse(in: rect)
                // Second pass intensifies the glow without widening it.
                context.strokeEllipse(in: rect)
                context.restoreGState()
            }
            if contrastEnabled {
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
                context.setLineWidth(4.5)
                context.strokeEllipse(in: rect)
            }
            context.setStrokeColor(color.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(2.5)
            context.strokeEllipse(in: rect)
        }

        switch centerStyle {
        case .plus:
            let arm: CGFloat = 7
            context.setLineCap(.round)
            func plus(strokeColor: NSColor, width: CGFloat) {
                context.setStrokeColor(strokeColor.cgColor)
                context.setLineWidth(width)
                context.move(to: CGPoint(x: point.x - arm, y: point.y))
                context.addLine(to: CGPoint(x: point.x + arm, y: point.y))
                context.move(to: CGPoint(x: point.x, y: point.y - arm))
                context.addLine(to: CGPoint(x: point.x, y: point.y + arm))
                context.strokePath()
            }
            if contrastEnabled {
                plus(strokeColor: NSColor.black.withAlphaComponent(0.35), width: 4)
            }
            plus(strokeColor: color.withAlphaComponent(0.95), width: 2)
        case .dot:
            let r: CGFloat = 3.5
            if contrastEnabled {
                let outer = CGRect(x: point.x - r - 1, y: point.y - r - 1,
                                   width: (r + 1) * 2, height: (r + 1) * 2)
                context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                context.fillEllipse(in: outer)
            }
            let inner = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
            context.setFillColor(color.withAlphaComponent(0.95).cgColor)
            context.fillEllipse(in: inner)
        case .none:
            break
        }

        context.restoreGState()
    }

    /// Fade fraction for an auto-disappearing item with the given age/life (1 until the last
    /// 0.5 s — or 35% of a short life — then linear to 0).
    private func fadeAlpha(age: TimeInterval, life: TimeInterval) -> CGFloat {
        let remaining = life - age
        guard remaining > 0 else { return 0 }
        let fadeWindow = min(0.5, life * 0.35)
        return fadeWindow > 0 ? min(1.0, CGFloat(remaining / fadeWindow)) : 1.0
    }

    /// Draw each fading snapshot layer (formerly-permanent strokes) under the timed shapes.
    private func drawTimedLayers(in context: CGContext) {
        guard !timedLayers.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for layer in timedLayers {
            let alpha = fadeAlpha(age: now - layer.drawnAt, life: layer.life)
            guard alpha > 0 else { continue }
            context.saveGState()
            context.setAlpha(alpha)
            context.draw(layer.image, in: bounds)
            context.restoreGState()
        }
    }

    /// Stroke each auto-disappearing shape, fading it out over the tail end of its life.
    private func drawTimedShapes(in context: CGContext) {
        guard !timedShapes.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for shape in timedShapes {
            let alpha = fadeAlpha(age: now - shape.drawnAt, life: shape.life)
            guard alpha > 0 else { continue }
            context.setStrokeColor(shape.color.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(shape.penWidth)
            context.addPath(shape.path)
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawBackground(in context: CGContext) {
        switch drawingState.backgroundMode {
        case .transparent:
            if let bg = backgroundImage {
                context.draw(bg, in: bounds)
            }
        case .whiteboard:
            context.setFillColor(NSColor.white.cgColor)
            context.fill(bounds)
        case .blackboard:
            context.setFillColor(NSColor.black.cgColor)
            context.fill(bounds)
        }
    }

    /// Darken everything outside `rect`. The rectangle area itself is left untouched
    /// (the layer below the spotlight stays visible).
    private func drawSpotlightMask(rect: CGRect, in context: CGContext) {
        let normalized = rect.standardized
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(drawingState.spotlightDarkness).cgColor)
        context.fill(bounds)
        context.setBlendMode(.clear)
        context.fill(normalized)
        context.restoreGState()
    }

    // MARK: - Laser Pointer

    override func mouseMoved(with event: NSEvent) {
        guard !isDragging else { return }
        // The halo follows every move. The laser trail is sampled when it's enabled in
        // Settings. (Upstream had a transient "hold ⇧ for laser" gesture, but it now
        // collides with ⌥⇧ + drag = arrow — the trail would appear as the user moved
        // the mouse before mouse-down. Rely on the Settings toggle only.)
        cursorInside = true
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        if Settings.shared.laserEnabled {
            let now = ProcessInfo.processInfo.systemUptime
            if now - appearTime >= Self.laserStartupGrace {
                appendLaserSamples(to: point, time: now)
                pruneLaserTrail(now: now)
                startLaserTimerIfNeeded()
            }
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        cursorInside = true
        cursorPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        // Cursor moved to another display — clear this overlay's halo/laser.
        cursorInside = false
        laserTrail.removeAll()
        needsDisplay = true
    }

    /// Drop trail points that have fully faded.
    private func pruneLaserTrail(now: TimeInterval) {
        laserTrail.removeAll { now - $0.time > Self.laserFadeDuration }
    }

    /// Append the new sample, plus enough linearly-interpolated intermediate samples
    /// that consecutive points are never further apart than the line cap diameter.
    /// Without this, fast cursor motion leaves the round caps visible as discrete
    /// "dots" along the trail because segments are longer than the line is wide.
    private func appendLaserSamples(to point: CGPoint, time: TimeInterval) {
        let maxSpacing: CGFloat = 5  // ~lineWidth/sqrt(2) so caps fully overlap
        if let last = laserTrail.last {
            let dx = point.x - last.location.x
            let dy = point.y - last.location.y
            let dist = hypot(dx, dy)
            if dist > maxSpacing {
                let steps = Int((dist / maxSpacing).rounded(.up))
                for k in 1..<steps {
                    let f = CGFloat(k) / CGFloat(steps)
                    let interp = CGPoint(x: last.location.x + dx * f,
                                         y: last.location.y + dy * f)
                    let interpTime = last.time + Double(f) * (time - last.time)
                    laserTrail.append(LaserPoint(location: interp, time: interpTime))
                }
            }
        }
        laserTrail.append(LaserPoint(location: point, time: time))
    }

    /// Run a ~60 Hz repaint while the trail is alive so it fades smoothly even
    /// when the cursor stops moving. Stops itself once the trail empties.
    private func startLaserTimerIfNeeded() {
        guard laserTimer == nil else { return }
        laserTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.pruneLaserTrail(now: now)
                self.needsDisplay = true
                if self.laserTrail.isEmpty {
                    self.laserTimer?.invalidate()
                    self.laserTimer = nil
                }
            }
        }
    }

    private func drawLaserTrail(in context: CGContext) {
        guard let headPoint = laserTrail.last else { return }
        let head = headPoint.location
        let now = ProcessInfo.processInfo.systemUptime
        let color = Settings.shared.resolvedNSColor

        if laserTrail.count >= 2 {
            // Smooth positions in-place; keep 1:1 correspondence with timestamps so each
            // segment fades on its own age. (The previous single-gradient approach made
            // the whole tail jump when the oldest sample aged out and got pruned.)
            let smoothed = FreehandRenderer.movingAverage(
                laserTrail.map(\.location), windowRadius: 2
            )

            func ageAlpha(_ t: TimeInterval) -> CGFloat {
                max(0, 1.0 - CGFloat((now - t) / Self.laserFadeDuration))
            }

            // Two passes: soft outer glow, then bright core. Same path geometry, different
            // widths. Round caps at every join — adjacent segments share an endpoint and
            // width so the caps overlap perfectly (no beads).
            for (width, maxAlpha) in [(CGFloat(18), CGFloat(0.14)), (CGFloat(6), CGFloat(0.5))] {
                context.saveGState()
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.setLineWidth(width)
                for i in 0..<(smoothed.count - 1) {
                    // Use the segment's NEWER endpoint age so the head end of each segment
                    // matches the next segment's tail end — alpha is continuous across joins.
                    let alpha = ageAlpha(laserTrail[i + 1].time) * maxAlpha
                    guard alpha > 0 else { continue }
                    context.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
                    context.move(to: smoothed[i])
                    context.addLine(to: smoothed[i + 1])
                    context.strokePath()
                }
                context.restoreGState()
            }
        }

        // Bright dot at the cursor head, tied to the head sample's own age.
        let headT = max(0, 1.0 - CGFloat((now - headPoint.time) / Self.laserFadeDuration))
        guard headT > 0 else { return }
        let r: CGFloat = 5.0
        context.saveGState()
        context.setFillColor(color.withAlphaComponent(0.30 * headT).cgColor)
        context.fillEllipse(in: CGRect(x: head.x - r - 4, y: head.y - r - 4,
                                       width: 2 * (r + 4), height: 2 * (r + 4)))
        context.setFillColor(color.withAlphaComponent(0.95 * headT).cgColor)
        context.fillEllipse(in: CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r))
        context.setFillColor(NSColor.white.withAlphaComponent(0.85 * headT).cgColor)
        context.fillEllipse(in: CGRect(x: head.x - 2.0, y: head.y - 2.0, width: 4.0, height: 4.0))
        context.restoreGState()
    }

    // MARK: - Click Pulse

    private func spawnClickPulseIfEnabled(at point: CGPoint) {
        guard Settings.shared.clickPulseEnabled else { return }
        let pulse = ClickPulse(origin: point,
                               startTime: ProcessInfo.processInfo.systemUptime,
                               color: Settings.shared.resolvedNSColor)
        clickPulses.append(pulse)
        startPulseTimerIfNeeded()
        needsDisplay = true
    }

    private func startPulseTimerIfNeeded() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.clickPulses.removeAll { now - $0.startTime > Self.pulseDuration }
                self.needsDisplay = true
                if self.clickPulses.isEmpty {
                    self.pulseTimer?.invalidate()
                    self.pulseTimer = nil
                }
            }
        }
    }

    private func drawClickPulses(in context: CGContext) {
        guard !clickPulses.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let startRadius = max(Settings.shared.haloSize, 10)
        let endRadius = startRadius * 2.5
        context.saveGState()
        for pulse in clickPulses {
            // Keep all the animation math in CGFloat so it composes cleanly with
            // startRadius/endRadius below (CGFloat is Double on 64-bit, so this
            // currently compiles, but the explicit conversion guards against the
            // mixed-type breakage if CGFloat ever becomes Float in some build).
            let t = CGFloat(min(1.0, max(0.0, (now - pulse.startTime) / Self.pulseDuration)))
            let eased = 1.0 - pow(1.0 - t, 3.0) // easeOutCubic
            let radius = startRadius + (endRadius - startRadius) * eased
            let alpha = (1.0 - t) * 0.55
            let rect = CGRect(x: pulse.origin.x - radius, y: pulse.origin.y - radius,
                              width: radius * 2, height: radius * 2)
            context.setStrokeColor(pulse.color.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(2.5)
            context.strokeEllipse(in: rect)
        }
        context.restoreGState()
    }

    // Scrolling needs no handling: while the overlay is transparent (the common case) scroll
    // events reach the app below natively; while interactive (⌥ held) we simply don't capture
    // scroll. No event injection, no Accessibility.

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        // Starting a drag cancels the laser trail.
        laserTrail.removeAll()
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        cursorPoint = point
        isDragging = true
        previewLayer = nil
        activeFreehand = nil
        freehandPoints = [point]
        // Both click feedback animations (the expanding ring pulse + the halo
        // press-compress) are gated by the same "Animate clicks" setting.
        if Settings.shared.clickPulseEnabled {
            spawnClickPulseIfEnabled(at: point)
            setHaloScaleTarget(Self.haloPressScale)
        }
    }

    /// Ease the halo toward `target`, running a short animation timer until it settles.
    /// Used to compress on mouse-down (target < 1) and pop back on mouse-up (target = 1).
    private func setHaloScaleTarget(_ target: CGFloat) {
        haloScaleTarget = target
        guard haloPressTimer == nil else { return }
        haloPressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.haloScale += (self.haloScaleTarget - self.haloScale) * Self.haloScaleEasing
                self.needsDisplay = true
                if abs(self.haloScale - self.haloScaleTarget) < 0.001 {
                    self.haloScale = self.haloScaleTarget
                    self.haloPressTimer?.invalidate()
                    self.haloPressTimer = nil
                }
            }
        }
    }

    /// ⇧+drag → arrow, ⌘+drag → rectangle, otherwise freehand draw.
    private func dragShapeType(for event: NSEvent) -> ShapeType {
        let mods = event.modifierFlags
        if mods.contains(.shift)   { return .arrow }
        if mods.contains(.command) { return .rectangle }
        return .freehand
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        cursorPoint = currentPoint
        switch dragShapeType(for: event) {
        case .arrow:
            activeFreehand = nil
            previewLayer = ShapeRenderer.arrowPath(from: currentPoint, to: dragOrigin,
                                                   penWidth: drawingState.penWidth)
        case .rectangle:
            activeFreehand = nil
            previewLayer = ShapeRenderer.rectanglePath(from: dragOrigin, to: currentPoint)
        default:
            previewLayer = nil
            freehandPoints.append(currentPoint)
            activeFreehand = FreehandRenderer.smoothedPath(from: freehandPoints)
        }
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        setHaloScaleTarget(1.0)  // release the compression
        guard isDragging else { return }
        isDragging = false

        let currentPoint = convert(event.locationInWindow, from: nil)
        cursorPoint = currentPoint
        let shapeType = dragShapeType(for: event)

        // Skip zero-size strokes (a click with no drag) so they don't inflate stats/undo.
        let dragged = hypot(currentPoint.x - dragOrigin.x, currentPoint.y - dragOrigin.y) > 3

        if dragged {
            let autoSecs = Settings.shared.autoDisappearSeconds
            // Auto-disappear applies only in a toggled (pinned) session, not a hold session
            // — a hold session already clears everything the moment you release the modifier.
            if autoSecs > 0, !exitsOnOptionRelease {
                addTimedShape(shapeType: shapeType, endPoint: currentPoint, life: autoSecs)
            } else {
                // Push current state for undo, then composite the shape into the finished layer.
                strokeManager.pushUndoSnapshot(
                    finishedLayer,
                    backgroundMode: drawingState.backgroundMode,
                    spotlightRect: drawingState.spotlightRect
                )
                finishedLayer = compositeStrokeOntoFinished(shapeType: shapeType, endPoint: currentPoint)
            }

            switch shapeType {
            case .arrow:     Settings.shared.arrowsDrawn += 1
            case .rectangle: Settings.shared.boxesDrawn += 1
            default:         break
            }

            OnboardingCoordinator.shared.recordShape(shapeType)
        }
        // A plain click (no drag) needs no special handling: the overlay only captures the
        // mouse while ⌥ is held, so to click the app below you simply release ⌥ (it's then
        // transparent and the click lands natively).

        previewLayer = nil
        activeFreehand = nil
        freehandPoints.removeAll()
        setNeedsDisplay(bounds)
    }

    /// The stroked path for a finished drag (box / arrow / freehand).
    private func shapePath(shapeType: ShapeType, endPoint: CGPoint) -> CGPath {
        switch shapeType {
        case .arrow:
            return ShapeRenderer.arrowPath(from: endPoint, to: dragOrigin,
                                           penWidth: drawingState.penWidth).cgPath
        case .freehand:
            return FreehandRenderer.smoothedPath(from: freehandPoints).cgPath
        default:
            return ShapeRenderer.rectanglePath(from: dragOrigin, to: endPoint).cgPath
        }
    }

    /// Record a shape that will fade out and remove itself after `life` seconds.
    private func addTimedShape(shapeType: ShapeType, endPoint: CGPoint, life: TimeInterval) {
        timedShapes.append(TimedShape(
            path: shapePath(shapeType: shapeType, endPoint: endPoint),
            color: drawingState.currentNSColor,
            penWidth: drawingState.penWidth,
            drawnAt: ProcessInfo.processInfo.systemUptime,
            life: life
        ))
        startAutoDisappearTimerIfNeeded()
    }

    /// Repaint ~60 Hz while any timed content is alive, pruning expired items. Self-stopping.
    private func startAutoDisappearTimerIfNeeded() {
        guard autoDisappearTimer == nil else { return }
        autoDisappearTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.timedShapes.removeAll { now - $0.drawnAt >= $0.life }
                self.timedLayers.removeAll { now - $0.drawnAt >= $0.life }
                self.needsDisplay = true
                if self.timedShapes.isEmpty && self.timedLayers.isEmpty {
                    self.autoDisappearTimer?.invalidate()
                    self.autoDisappearTimer = nil
                }
            }
        }
    }

    /// Apply a newly-chosen auto-disappear timeout (⌥0–9) to what's *already* on screen, so it
    /// behaves as the user expects:
    ///  • life > 0 — fade everything currently visible `life` seconds from now. Strokes that
    ///    were permanent (`finishedLayer`) become a fading snapshot; already-timed items are
    ///    re-timed to the new value.
    ///  • life == 0 — turn auto-disappear off: bake whatever is mid-fade back to permanent.
    /// Only acts in a pinned session (a hold session's strokes clear on ⌥ release regardless).
    func setAutoDisappearLife(_ life: TimeInterval) {
        guard !exitsOnOptionRelease else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if life > 0 {
            if let layer = finishedLayer {
                timedLayers.append(TimedLayer(image: layer, drawnAt: now, life: life))
                finishedLayer = nil
            }
            timedLayers = timedLayers.map { TimedLayer(image: $0.image, drawnAt: now, life: life) }
            timedShapes = timedShapes.map {
                TimedShape(path: $0.path, color: $0.color, penWidth: $0.penWidth, drawnAt: now, life: life)
            }
            if !timedLayers.isEmpty || !timedShapes.isEmpty { startAutoDisappearTimerIfNeeded() }
        } else {
            bakeTimedContentIntoFinished()
        }
        setNeedsDisplay(bounds)
    }

    /// Composite all currently-fading content back into the permanent `finishedLayer` (used
    /// when auto-disappear is turned off so existing shapes stop fading and stay).
    private func bakeTimedContentIntoFinished() {
        guard !timedLayers.isEmpty || !timedShapes.isEmpty else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0, let ctx = CGContext.createBitmapContext(size: size) else { return }
        let full = CGRect(origin: .zero, size: size)
        if let existing = finishedLayer { ctx.draw(existing, in: full) }
        for layer in timedLayers { ctx.draw(layer.image, in: full) }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for shape in timedShapes {
            ctx.setStrokeColor(shape.color.cgColor)
            ctx.setLineWidth(shape.penWidth)
            ctx.addPath(shape.path)
            ctx.strokePath()
        }
        finishedLayer = ctx.makeImage()
        timedShapes.removeAll()
        timedLayers.removeAll()
        autoDisappearTimer?.invalidate()
        autoDisappearTimer = nil
    }

    // MARK: - Erase / Undo (driven by draw-mode hotkeys)

    /// Clear everything on the canvas (E while drawing). Undoable in persistent mode.
    func clearCanvas() {
        if finishedLayer != nil || drawingState.spotlightRect != nil {
            strokeManager.pushUndoSnapshot(
                finishedLayer,
                backgroundMode: drawingState.backgroundMode,
                spotlightRect: drawingState.spotlightRect
            )
        }
        finishedLayer = nil
        timedShapes.removeAll()
        timedLayers.removeAll()
        drawingState.spotlightRect = nil
        setNeedsDisplay(bounds)
    }

    /// Undo the most recent shape (Z while drawing). Removes the latest auto-disappearing
    /// shape first, otherwise steps back through the composited undo history.
    func undo() {
        if !timedShapes.isEmpty {
            timedShapes.removeLast()
            setNeedsDisplay(bounds)
            return
        }
        performUndo()
    }

    // MARK: - Keyboard Events

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers?.uppercased() else { return }
        let modifiers = event.modifierFlags

        switch characters {
        // Exit draw mode.
        case "\u{1B}": // Escape
            onDismiss?()

        // Undo the last box (⌘Z).
        case "Z" where modifiers.contains(.command):
            performUndo()

        default:
            break
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Spring-loaded entry (hold Option): releasing Option exits Draw mode.
        if exitsOnOptionRelease && !event.modifierFlags.contains(Settings.shared.holdModifier.flag) {
            onDismiss?()
        }
    }

    // MARK: - Compositing

    /// Renders the current stroke onto finishedLayer and returns the new CGImage.
    private func compositeStrokeOntoFinished(shapeType: ShapeType, endPoint: CGPoint) -> CGImage? {
        let size = bounds.size
        guard size.width > 0 && size.height > 0 else { return finishedLayer }

        guard let bitmapContext = CGContext.createBitmapContext(size: size) else {
            return finishedLayer
        }

        // Draw existing finished layer
        if let existing = finishedLayer {
            bitmapContext.draw(existing, in: CGRect(origin: .zero, size: size))
        }

        // Set stroke properties
        let color = drawingState.currentNSColor
        if drawingState.isHighlighterMode {
            // .multiply is invisible on transparent pixels; use .normal when no background image
            let blendMode: CGBlendMode = (backgroundImage != nil) ? .multiply : .normal
            bitmapContext.setBlendMode(blendMode)
            bitmapContext.setStrokeColor(color.cgColor)
            bitmapContext.setLineWidth(drawingState.penWidth * Settings.shared.highlighterWidthMultiplier)
            bitmapContext.setLineCap(.square)
            bitmapContext.setLineJoin(.round)
        } else {
            bitmapContext.setStrokeColor(color.cgColor)
            bitmapContext.setLineWidth(drawingState.penWidth)
            bitmapContext.setLineCap(.round)
            bitmapContext.setLineJoin(.round)
        }

        // Draw the stroke
        let path: CGPath
        switch shapeType {
        case .freehand:
            let bezier = FreehandRenderer.smoothedPath(from: freehandPoints)
            path = bezier.cgPath
        case .line:
            path = ShapeRenderer.linePath(from: dragOrigin, to: endPoint).cgPath
        case .rectangle:
            path = ShapeRenderer.rectanglePath(from: dragOrigin, to: endPoint).cgPath
        case .ellipse:
            path = ShapeRenderer.ellipsePath(from: dragOrigin, to: endPoint).cgPath
        case .arrow:
            // Tip (arrowhead) at the cursor (endPoint), tail at the drag origin.
            path = ShapeRenderer.arrowPath(from: endPoint, to: dragOrigin, penWidth: drawingState.penWidth).cgPath
        }

        bitmapContext.addPath(path)
        bitmapContext.strokePath()

        return bitmapContext.makeImage()
    }

    // MARK: - Undo

    private func performUndo() {
        if let snapshot = strokeManager.popUndoSnapshot() {
            finishedLayer = snapshot.finishedLayer
            drawingState.backgroundMode = snapshot.backgroundMode
            drawingState.spotlightRect = snapshot.spotlightRect
        } else {
            finishedLayer = nil
            drawingState.spotlightRect = nil
        }
        setNeedsDisplay(bounds)
    }

    // MARK: - Text Mode

    private func enterTextMode() {
        drawingState.isTextMode = true
        let controller = TextInputController(canvasView: self, drawingState: drawingState)
        controller.onCommit = { [weak self] in
            self?.commitText()
        }
        textInputController = controller
    }

    private func handleTextModeClick(_ event: NSEvent) {
        // Commit any existing text before placing a new text field
        commitCurrentText()
        let point = convert(event.locationInWindow, from: nil)
        textInputController?.placeTextField(at: point)
    }

    /// Rasterize current text into finishedLayer without leaving text mode.
    private func commitCurrentText() {
        guard let controller = textInputController, controller.hasText else { return }
        strokeManager.pushUndoSnapshot(
            finishedLayer,
            backgroundMode: drawingState.backgroundMode,
            spotlightRect: drawingState.spotlightRect
        )
        finishedLayer = controller.rasterizeAndComposite(onto: finishedLayer, canvasSize: bounds.size)
        controller.cleanup()
        setNeedsDisplay(bounds)
    }

    /// Commit current text and exit text mode (return to pen mode).
    private func commitText() {
        commitCurrentText()
        textInputController?.cleanup()
        textInputController = nil
        drawingState.isTextMode = false
        setNeedsDisplay(bounds)
    }

    // MARK: - Export

    private func copyToClipboard() async {
        guard let image = await renderFinalImage() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(cgImage: image, size: bounds.size)
        pasteboard.writeObjects([nsImage])
    }

    private func saveToFile() async {
        guard let image = await renderFinalImage() else { return }
        guard let window = self.window else { return }

        // Hide the overlay so the save panel is accessible.
        // The rendered image is already captured, so the data is safe.
        window.orderOut(nil)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "ZoomacIt-draw.png"

        let response = await withCheckedContinuation { continuation in
            savePanel.begin { panelResponse in
                continuation.resume(returning: panelResponse)
            }
        }

        // Restore overlay
        window.makeKeyAndOrderFront(nil)

        guard response == .OK, let url = savePanel.url else { return }

        let nsImage = NSImage(cgImage: image, size: self.bounds.size)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        try? pngData.write(to: url)
    }

    /// Renders the full canvas (background + finishedLayer) as a CGImage.
    /// When in live draw mode (no backgroundImage), captures the current desktop on demand.
    private func renderFinalImage() async -> CGImage? {
        let size = bounds.size
        guard let context = CGContext.createBitmapContext(size: size) else { return nil }

        // Background
        switch drawingState.backgroundMode {
        case .transparent:
            if let bg = backgroundImage {
                // Zoom→Draw transition: use frozen snapshot
                context.draw(bg, in: CGRect(origin: .zero, size: size))
            } else {
                // Live draw mode: capture desktop on demand (excluding our overlay)
                if let captured = await captureDesktopExcludingOverlay() {
                    context.draw(captured, in: CGRect(origin: .zero, size: size))
                }
                // If capture fails (no permission), export as transparent PNG
            }
        case .whiteboard:
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        case .blackboard:
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }

        // Spotlight mask — placed under the strokes so drawings remain visible
        // both inside and outside the spotlight rectangle.
        if let rect = drawingState.spotlightRect {
            let exportBounds = CGRect(origin: .zero, size: size)
            context.saveGState()
            context.setFillColor(NSColor.black.withAlphaComponent(drawingState.spotlightDarkness).cgColor)
            context.fill(exportBounds)
            context.setBlendMode(.clear)
            context.fill(rect.standardized)
            context.restoreGState()
        }

        // Finished strokes
        if let finished = finishedLayer {
            context.draw(finished, in: CGRect(origin: .zero, size: size))
        }

        return context.makeImage()
    }

    // MARK: - On-Demand Desktop Capture

    /// Captures the current desktop excluding the overlay window.
    /// Uses ScreenCaptureKit's excludingWindows filter to avoid flicker.
    private func captureDesktopExcludingOverlay() async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("[DrawingCanvasView] Screen Recording not permitted — exporting strokes only.")
            return nil
        }

        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
        let scaleFactor = screen.backingScaleFactor

        do {
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = availableContent.displays.first(where: { $0.displayID == screenNumber }) else {
                NSLog("[DrawingCanvasView] Display not found for on-demand capture.")
                return nil
            }

            // Exclude our overlay window from the capture
            let excludedWindows: [SCWindow]
            if let overlayWindowNumber = window?.windowNumber, overlayWindowNumber > 0 {
                excludedWindows = availableContent.windows.filter { $0.windowID == CGWindowID(overlayWindowNumber) }
            } else {
                NSLog("[DrawingCanvasView] Overlay windowNumber unavailable; proceeding without exclusion.")
                excludedWindows = []
            }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * scaleFactor)
            config.height = Int(screen.frame.height * scaleFactor)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            NSLog("[DrawingCanvasView] On-demand capture failed: %@", error.localizedDescription)
            return nil
        }
    }
}
