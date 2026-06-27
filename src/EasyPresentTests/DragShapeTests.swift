import XCTest
import AppKit
@testable import EasyPresent

/// Covers the pure modifier → shape mapping that backs both the drag handler and the
/// cursor. The plain-drag vs ⌘-drag pair (box / freehand) is swappable; arrow (⇧) is not.
final class DragShapeTests: XCTestCase {

    private func shape(_ mods: NSEvent.ModifierFlags, plainBox: Bool) -> ShapeType {
        DrawingCanvasView.dragShape(modifiers: mods, plainDragDrawsBox: plainBox)
    }

    // MARK: plainDragDrawsBox == true (default)

    func testBoxDefault_plainIsBox() {
        XCTAssertEqual(shape([], plainBox: true), .rectangle)
    }

    func testBoxDefault_commandIsFreehand() {
        XCTAssertEqual(shape(.command, plainBox: true), .freehand)
    }

    // MARK: plainDragDrawsBox == false (swapped)

    func testFreehandMode_plainIsFreehand() {
        XCTAssertEqual(shape([], plainBox: false), .freehand)
    }

    func testFreehandMode_commandIsBox() {
        XCTAssertEqual(shape(.command, plainBox: false), .rectangle)
    }

    // MARK: arrow is independent of the setting

    func testShiftIsArrowRegardlessOfSetting() {
        XCTAssertEqual(shape(.shift, plainBox: true), .arrow)
        XCTAssertEqual(shape(.shift, plainBox: false), .arrow)
    }

    func testShiftWinsOverCommand() {
        XCTAssertEqual(shape([.shift, .command], plainBox: true), .arrow)
        XCTAssertEqual(shape([.shift, .command], plainBox: false), .arrow)
    }
}
