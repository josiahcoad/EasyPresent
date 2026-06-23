import AppKit
import SwiftUI

/// Manages the Settings window (NSWindow hosting SwiftUI SettingsView).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    func showWindow() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "EasyPresent Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 540))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The grouped Form sits on a textured grey backdrop. The default window
        // background is plain white, which produced a visible white stripe
        // between the tab picker and the form. Matching them removes that band.
        window.backgroundColor = NSColor.windowBackgroundColor
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            BreakTimerWindowController.stopTestSound()
        }
    }
}
