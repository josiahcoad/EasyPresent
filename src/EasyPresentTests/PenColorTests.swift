import XCTest
@testable import EasyPresent

final class PenColorTests: XCTestCase {

    func testAllCasesCount() {
        XCTAssertEqual(PenColor.allCases.count, 6)
    }

    func testNSColorMapping() {
        XCTAssertEqual(PenColor.red.nsColor, .systemRed)
        XCTAssertEqual(PenColor.green.nsColor, .systemGreen)
        XCTAssertEqual(PenColor.cyan.nsColor, .systemCyan)
        XCTAssertEqual(PenColor.orange.nsColor, .systemOrange)
        XCTAssertEqual(PenColor.yellow.nsColor, .systemYellow)
        XCTAssertEqual(PenColor.magenta.nsColor, .magenta)
    }

    func testFromCharacterCaseInsensitive() {
        XCTAssertEqual(PenColor.from(character: "r"), .red)
        XCTAssertEqual(PenColor.from(character: "R"), .red)
        XCTAssertEqual(PenColor.from(character: "g"), .green)
        XCTAssertEqual(PenColor.from(character: "G"), .green)
    }

    func testFromCharacterInvalidReturnsNil() {
        XCTAssertNil(PenColor.from(character: "X"))
        XCTAssertNil(PenColor.from(character: ""))
        XCTAssertNil(PenColor.from(character: "1"))
    }

    func testEveryColorHasCharacterMapping() {
        let chars = ["R", "G", "C", "O", "Y", "M"]
        let mapped = chars.compactMap { PenColor.from(character: $0) }
        XCTAssertEqual(mapped.count, PenColor.allCases.count,
                       "Every PenColor should be reachable via a character")
        XCTAssertEqual(Set(mapped).count, PenColor.allCases.count,
                       "Each character should map to a unique color")
    }

    func testRawValueRoundTrip() {
        for color in PenColor.allCases {
            let restored = PenColor(rawValue: color.rawValue)
            XCTAssertEqual(restored, color, "Round-trip failed for \(color)")
        }
    }

    // MARK: - Color cycling (⌥↑ / ⌥↓ while drawing)

    func testNextAdvancesInOrder() {
        XCTAssertEqual(PenColor.red.next, .green)
        XCTAssertEqual(PenColor.green.next, .cyan)
    }

    func testNextWrapsAround() {
        XCTAssertEqual(PenColor.allCases.last?.next, PenColor.allCases.first)
    }

    func testPreviousWrapsAround() {
        XCTAssertEqual(PenColor.allCases.first?.previous, PenColor.allCases.last)
    }

    func testNextAndPreviousAreInverse() {
        for color in PenColor.allCases {
            XCTAssertEqual(color.next.previous, color)
            XCTAssertEqual(color.previous.next, color)
        }
    }

    func testCyclingAllForwardVisitsEveryColorOnce() {
        var seen: [PenColor] = []
        var c = PenColor.red
        for _ in PenColor.allCases {
            seen.append(c)
            c = c.next
        }
        XCTAssertEqual(Set(seen).count, PenColor.allCases.count)
        XCTAssertEqual(c, .red, "A full cycle should return to the start")
    }
}
