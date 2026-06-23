import XCTest
import Carbon.HIToolbox
@testable import EasyPresent

/// Locks in the presenter-mode behaviors added in the EasyPresent fork.
final class ActivationModifierTests: XCTestCase {

    func testCasesAndOrder() {
        XCTAssertEqual(ActivationModifier.allCases, [.option, .control, .command])
    }

    func testEventFlags() {
        XCTAssertEqual(ActivationModifier.option.flag, .option)
        XCTAssertEqual(ActivationModifier.control.flag, .control)
        XCTAssertEqual(ActivationModifier.command.flag, .command)
    }

    func testCarbonFlags() {
        XCTAssertEqual(ActivationModifier.option.carbonFlag, UInt32(optionKey))
        XCTAssertEqual(ActivationModifier.control.carbonFlag, UInt32(controlKey))
        XCTAssertEqual(ActivationModifier.command.carbonFlag, UInt32(cmdKey))
    }

    func testSymbols() {
        XCTAssertEqual(ActivationModifier.option.symbol, "⌥")
        XCTAssertEqual(ActivationModifier.control.symbol, "⌃")
        XCTAssertEqual(ActivationModifier.command.symbol, "⌘")
    }

    func testRawValueRoundTrip() {
        for m in ActivationModifier.allCases {
            XCTAssertEqual(ActivationModifier(rawValue: m.rawValue), m)
        }
    }
}

final class EasyPresentSettingsDefaultsTests: XCTestCase {

    /// Verify the registered defaults by clearing any persisted override, then reading.
    func testRegisteredDefaults() {
        _ = Settings.shared  // ensure registerDefaults() has run
        let d = UserDefaults.standard
        for key in [Settings.Keys.color, Settings.Keys.laserEnabled, Settings.Keys.holdModifier,
                    Settings.Keys.toggleHotkeyKeyCode, Settings.Keys.toggleHotkeyModifiers,
                    Settings.Keys.onboardingCompleted] {
            d.removeObject(forKey: key)
        }

        XCTAssertEqual(Settings.shared.color, .red)
        XCTAssertFalse(Settings.shared.laserEnabled)
        XCTAssertEqual(Settings.shared.holdModifier, .option)
        XCTAssertEqual(Settings.shared.toggleHotkeyKeyCode, UInt32(kVK_Space))
        XCTAssertEqual(Settings.shared.toggleHotkeyModifiers, UInt32(optionKey))
        XCTAssertFalse(Settings.shared.onboardingCompleted)
    }

    func testToggleDisplayStringDefault() {
        Settings.shared.toggleHotkeyKeyCode = UInt32(kVK_Space)
        Settings.shared.toggleHotkeyModifiers = UInt32(optionKey)
        XCTAssertEqual(Settings.shared.toggleDisplayString, "⌥Space")
    }

    func testStatsRoundTrip() {
        Settings.shared.boxesDrawn = 7
        Settings.shared.arrowsDrawn = 3
        Settings.shared.drawSessions = 12
        XCTAssertEqual(Settings.shared.boxesDrawn, 7)
        XCTAssertEqual(Settings.shared.arrowsDrawn, 3)
        XCTAssertEqual(Settings.shared.drawSessions, 12)
    }
}
