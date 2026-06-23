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

    /// Whether the system cursor is currently hidden (balanced hide/unhide).
    private var didHideCursor = false

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

    /// Pins the halo to the live cursor by re-reading the global mouse location every
    /// tick and converting through the window. This is self-correcting: it stays exact
    /// even if the overlay window is repositioned after it appears (which otherwise made
    /// the halo "slide out" near screen edges) or the cursor crosses displays.
    private var cursorTrackTimer: Timer?

    /// Tracking area so `mouseMoved` fires across the whole view (no button down).
    private var mouseTrackingArea: NSTrackingArea?

    /// How long (seconds) a trail point takes to fully fade out.
    private static let laserFadeDuration: TimeInterval = 0.5

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
        if !didHideCursor {
            // CGDisplayHideCursor works window-server-wide, so it hides the system
            // cursor even though our overlay is a non-activating (background) panel.
            CGDisplayHideCursor(CGMainDisplayID())
            didHideCursor = true
        }
        // Pin the halo to the cursor continuously. A one-shot seed isn't enough: the
        // window can still be repositioned by AppKit just after it appears, which would
        // leave the halo drawn at stale window-local coordinates until the first move.
        syncCursorToGlobalMouse()
        startCursorTrackingIfNeeded()
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
            laserTrail.removeAll()
            if didHideCursor {
                CGDisplayShowCursor(CGMainDisplayID())
                didHideCursor = false
            }
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

        // 5. Halo ring + laser trail — only on the display the cursor is currently over.
        if cursorInside {
            drawHalo(in: context)
            drawLaserTrail(in: context)
        }
    }

    /// A soft glowing ring centered on the cursor so the audience can find the pointer.
    private func drawHalo(in context: CGContext) {
        let haloColor = Settings.shared.color.nsColor
        let radius: CGFloat = 22
        let rect = CGRect(x: cursorPoint.x - radius, y: cursorPoint.y - radius,
                          width: radius * 2, height: radius * 2)
        context.saveGState()
        // Soft filled glow.
        context.setFillColor(haloColor.withAlphaComponent(0.18).cgColor)
        context.fillEllipse(in: rect)
        // Crisp ring with a dark contrast edge so it shows on any background.
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(4.5)
        context.strokeEllipse(in: rect)
        context.setStrokeColor(haloColor.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(2.5)
        context.strokeEllipse(in: rect)

        // "+" crosshair marking the exact pointer position at the halo center.
        let arm: CGFloat = 7
        context.setLineCap(.round)
        func plus(color: NSColor, width: CGFloat) {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.move(to: CGPoint(x: cursorPoint.x - arm, y: cursorPoint.y))
            context.addLine(to: CGPoint(x: cursorPoint.x + arm, y: cursorPoint.y))
            context.move(to: CGPoint(x: cursorPoint.x, y: cursorPoint.y - arm))
            context.addLine(to: CGPoint(x: cursorPoint.x, y: cursorPoint.y + arm))
            context.strokePath()
        }
        plus(color: NSColor.black.withAlphaComponent(0.35), width: 4)  // contrast underlay
        plus(color: haloColor.withAlphaComponent(0.95), width: 2)
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
        // In presenter Draw mode every move feeds the halo + laser trail (no modifier gate).
        cursorInside = true
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        if Settings.shared.laserEnabled {
            let now = ProcessInfo.processInfo.systemUptime
            laserTrail.append(LaserPoint(location: point, time: now))
            pruneLaserTrail(now: now)
            startLaserTimerIfNeeded()
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
        // Whole-trail freshness — lets the streak dim away gracefully once the cursor stops.
        let globalT = max(0.0, 1.0 - (now - headPoint.time) / Self.laserFadeDuration)

        // Stroke the entire trail as ONE continuous path and fill the stroked region
        // with a tail→head gradient. (Stroking each sample segment separately left a
        // round line-cap at every sample, which read as beads along the trail.)
        if laserTrail.count >= 2 {
            let path = CGMutablePath()
            path.move(to: laserTrail[0].location)
            for point in laserTrail.dropFirst() { path.addLine(to: point.location) }
            let tail = laserTrail[0].location
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            // Soft outer glow, then bright core — same path, different width/alpha.
            drawLaserBand(path, width: 18, maxAlpha: 0.28 * globalT, from: tail, to: head,
                          colorSpace: colorSpace, in: context)
            drawLaserBand(path, width: 6, maxAlpha: 1.0 * globalT, from: tail, to: head,
                          colorSpace: colorSpace, in: context)
        }

        // Bright dot at the cursor head.
        guard globalT > 0 else { return }
        let r: CGFloat = 5.0
        context.saveGState()
        context.setFillColor(Settings.shared.color.nsColor.withAlphaComponent(0.30 * globalT).cgColor)
        context.fillEllipse(in: CGRect(x: head.x - r - 4, y: head.y - r - 4,
                                       width: 2 * (r + 4), height: 2 * (r + 4)))
        context.setFillColor(Settings.shared.color.nsColor.withAlphaComponent(0.95 * globalT).cgColor)
        context.fillEllipse(in: CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r))
        context.setFillColor(NSColor.white.withAlphaComponent(0.85 * globalT).cgColor)
        context.fillEllipse(in: CGRect(x: head.x - 2.0, y: head.y - 2.0, width: 4.0, height: 4.0))
        context.restoreGState()
    }

    /// Stroke `path` once and fill the stroked region with a transparent→red gradient
    /// running tail→head, producing a smooth (bead-free) comet streak.
    private func drawLaserBand(_ path: CGPath, width: CGFloat, maxAlpha: CGFloat,
                               from tail: CGPoint, to head: CGPoint,
                               colorSpace: CGColorSpace, in context: CGContext) {
        guard maxAlpha > 0 else { return }
        context.saveGState()
        context.addPath(path)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(width)
        context.replacePathWithStrokedPath()
        context.clip()
        let colors = [
            Settings.shared.color.nsColor.withAlphaComponent(0).cgColor,
            Settings.shared.color.nsColor.withAlphaComponent(maxAlpha).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: tail, end: head,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.restoreGState()
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        // Starting a box drag cancels the laser trail.
        laserTrail.removeAll()
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        cursorPoint = point
        isDragging = true
        previewLayer = nil
    }

    /// ⌥⇧+drag draws an arrow; a plain ⌥+drag draws a box.
    private func dragShapeType(for event: NSEvent) -> ShapeType {
        event.modifierFlags.contains(.shift) ? .arrow : .rectangle
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        cursorPoint = currentPoint
        switch dragShapeType(for: event) {
        case .arrow:
            // Tip (arrowhead) at the cursor, tail at the drag origin.
            previewLayer = ShapeRenderer.arrowPath(from: currentPoint, to: dragOrigin,
                                                   penWidth: drawingState.penWidth)
        default:
            previewLayer = ShapeRenderer.rectanglePath(from: dragOrigin, to: currentPoint)
        }
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false

        let currentPoint = convert(event.locationInWindow, from: nil)
        cursorPoint = currentPoint
        let shapeType = dragShapeType(for: event)

        // Skip zero-size shapes (a click with no drag) so they don't inflate stats/undo.
        let dragged = hypot(currentPoint.x - dragOrigin.x, currentPoint.y - dragOrigin.y) > 3

        if dragged {
            // Push current state for undo, then composite the shape into the finished layer.
            strokeManager.pushUndoSnapshot(
                finishedLayer,
                backgroundMode: drawingState.backgroundMode,
                spotlightRect: drawingState.spotlightRect
            )
            finishedLayer = compositeStrokeOntoFinished(shapeType: shapeType, endPoint: currentPoint)

            // Local usage counters.
            switch shapeType {
            case .arrow: Settings.shared.arrowsDrawn += 1
            default:     Settings.shared.boxesDrawn += 1
            }

            // Advance the guided onboarding when the expected shape is drawn.
            OnboardingCoordinator.shared.recordShape(shapeType)
        }

        previewLayer = nil
        setNeedsDisplay(bounds)
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
