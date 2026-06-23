import XCTest
@testable import EasyPresent

final class DrawingStateTests: XCTestCase {

    func testDefaultState() {
        let state = DrawingState()
        XCTAssertEqual(state.penWidth, 3.0)
        XCTAssertFalse(state.isHighlighterMode)
        XCTAssertFalse(state.isTextMode)
        XCTAssertFalse(state.isTabHeld)
    }

    func testPenWidthBounds() {
        let state = DrawingState()

        // Decrease to minimum
        for _ in 0..<100 {
            state.decreasePenWidth()
        }
        XCTAssertEqual(state.penWidth, 1.0)

        // Increase to maximum
        for _ in 0..<100 {
            state.increasePenWidth()
        }
        XCTAssertEqual(state.penWidth, 50.0)
    }

    func testColorMapping() {
        XCTAssertEqual(PenColor.from(character: "R"), .red)
        XCTAssertEqual(PenColor.from(character: "g"), .green)
        XCTAssertEqual(PenColor.from(character: "C"), .cyan)
        XCTAssertEqual(PenColor.from(character: "O"), .orange)
        XCTAssertEqual(PenColor.from(character: "Y"), .yellow)
        XCTAssertEqual(PenColor.from(character: "M"), .magenta)
        XCTAssertNil(PenColor.from(character: "Z"))
    }

    // MARK: - Shape Type from Modifiers

    func testShapeTypeFreehandNoModifiers() {
        let state = DrawingState()
        let shape = state.currentShapeType(modifiers: [])
        XCTAssertEqual(shape, .freehand)
    }

    func testShapeTypeLineWithShift() {
        let state = DrawingState()
        let shape = state.currentShapeType(modifiers: .shift)
        XCTAssertEqual(shape, .line)
    }

    func testShapeTypeRectangleWithControl() {
        let state = DrawingState()
        let shape = state.currentShapeType(modifiers: .control)
        XCTAssertEqual(shape, .rectangle)
    }

    func testShapeTypeArrowWithShiftControl() {
        let state = DrawingState()
        let shape = state.currentShapeType(modifiers: [.shift, .control])
        XCTAssertEqual(shape, .arrow)
    }

    func testShapeTypeEllipseWithTab() {
        let state = DrawingState()
        state.isTabHeld = true
        let shape = state.currentShapeType(modifiers: [])
        XCTAssertEqual(shape, .ellipse)
    }

    func testShapeTypeTabOverridesOtherModifiers() {
        let state = DrawingState()
        state.isTabHeld = true
        let shape = state.currentShapeType(modifiers: [.shift, .control])
        XCTAssertEqual(shape, .ellipse, "Tab should take priority over other modifiers")
    }

    // MARK: - Current NSColor

    func testCurrentNSColorReflectsSettingsColor() {
        let state = DrawingState()
        Settings.shared.color = .cyan
        XCTAssertEqual(state.currentNSColor, NSColor.systemCyan)
        Settings.shared.color = .magenta
        XCTAssertEqual(state.currentNSColor, NSColor.magenta)
    }

    // MARK: - Background Mode

    func testDefaultBackgroundMode() {
        let state = DrawingState()
        switch state.backgroundMode {
        case .transparent: break
        default: XCTFail("Default background should be .transparent")
        }
    }

    // MARK: - Spotlight

    func testDefaultSpotlightState() {
        let state = DrawingState()
        XCTAssertEqual(state.activeTool, .draw)
        XCTAssertNil(state.spotlightRect)
        XCTAssertEqual(state.spotlightDarkness, Settings.shared.spotlightDarkness, accuracy: 0.001)
    }

    func testSpotlightDarknessUpperBound() {
        let state = DrawingState()
        state.spotlightDarkness = 0.85
        for _ in 0..<10 {
            state.increaseSpotlightDarkness()
        }
        XCTAssertEqual(state.spotlightDarkness, DrawingState.spotlightDarknessMax, accuracy: 0.001)
    }

    func testSpotlightDarknessLowerBound() {
        let state = DrawingState()
        state.spotlightDarkness = 0.15
        for _ in 0..<10 {
            state.decreaseSpotlightDarkness()
        }
        XCTAssertEqual(state.spotlightDarkness, DrawingState.spotlightDarknessMin, accuracy: 0.001)
    }

    func testSpotlightDarknessStepSize() {
        let state = DrawingState()
        state.spotlightDarkness = 0.5
        state.increaseSpotlightDarkness()
        XCTAssertEqual(state.spotlightDarkness, 0.5 + DrawingState.spotlightDarknessStep, accuracy: 0.001)
        state.decreaseSpotlightDarkness()
        XCTAssertEqual(state.spotlightDarkness, 0.5, accuracy: 0.001)
    }

    func testActiveToolTransitions() {
        let state = DrawingState()
        XCTAssertEqual(state.activeTool, .draw)
        state.activeTool = .spotlight
        XCTAssertEqual(state.activeTool, .spotlight)
        state.activeTool = .draw
        XCTAssertEqual(state.activeTool, .draw)
    }
}
