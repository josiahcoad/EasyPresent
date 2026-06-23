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
}
