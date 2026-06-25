import AppKit
import Carbon.HIToolbox

@MainActor
final class StatusBarController: NSObject {

    private var statusItem: NSStatusItem?
    var onPreferences: (() -> Void)?

    override init() {
        super.init()
        setupStatusItem()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidReset),
            name: .settingsDidReset, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(hotkeysDidChange),
            name: .hotkeysDidChange, object: nil
        )
    }

    @objc private func settingsDidReset() {
        rebuildMenu()
    }

    @objc private func hotkeysDidChange() {
        rebuildMenu()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        NSLog("[StatusBar] statusItem created: %@", statusItem != nil ? "yes" : "no")

        guard let button = statusItem?.button else {
            NSLog("[StatusBar] ERROR: button is nil")
            return
        }

        // Use custom menu bar icon from asset catalog
        if let image = NSImage(named: "MenuBarIcon") {
            image.isTemplate = true
            button.image = image
            NSLog("[StatusBar] Icon set successfully")
        } else {
            // Fallback: use SF Symbol
            if let sfImage = NSImage(systemSymbolName: "pencil.and.outline",
                                     accessibilityDescription: "EasyPresent") {
                sfImage.isTemplate = true
                button.image = sfImage
            } else {
                button.title = "Z"
            }
            NSLog("[StatusBar] Custom icon not found, using fallback")
        }

        statusItem?.menu = buildMenu()
        NSLog("[StatusBar] Menu assigned")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Toggle highlight — same action as the user's configurable toggle hotkey
        // (base + recorded key, e.g. ⌥Space). Show the shortcut on the right.
        let toggleKeyCode = Settings.shared.toggleHotkeyKeyCode
        let toggleItem = NSMenuItem(
            title: "Toggle highlight",
            action: #selector(toggleAction),
            keyEquivalent: Self.menuKeyEquivalent(for: toggleKeyCode)
        )
        toggleItem.keyEquivalentModifierMask = Settings.carbonToNSEventModifiers(
            Settings.shared.holdModifier.carbonFlag
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(preferencesAction), keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = [.command]
        prefsItem.target = self
        menu.addItem(prefsItem)

        let aboutItem = NSMenuItem(title: "About EasyPresent", action: #selector(aboutAction), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit EasyPresent", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc private func toggleAction() {
        HotkeyManager.shared.onDrawToggleHotkey?()
    }

    /// Convert a Carbon key code to the single-character form `NSMenuItem`
    /// expects for its `keyEquivalent`. Special keys (Space, arrows, return)
    /// need their unicode/whitespace character, not the display label.
    private static func menuKeyEquivalent(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space:      return " "
        case kVK_Return:     return "\r"
        case kVK_Tab:        return "\t"
        case kVK_Escape:     return "\u{1b}"
        case kVK_LeftArrow:  return String(UnicodeScalar(0xF702)!)
        case kVK_RightArrow: return String(UnicodeScalar(0xF703)!)
        case kVK_UpArrow:    return String(UnicodeScalar(0xF700)!)
        case kVK_DownArrow:  return String(UnicodeScalar(0xF701)!)
        default:             return Settings.keyCodeToMenuCharacter(keyCode)
        }
    }

    @objc private func preferencesAction() {
        onPreferences?()
    }

    @objc private func aboutAction() {
        let credits = NSMutableAttributedString()
        let repoURL = URL(string: "https://github.com/josiahcoad/EasyPresent")!
        credits.append(NSAttributedString(
            string: "https://github.com/josiahcoad/EasyPresent",
            attributes: [
                .link: repoURL,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        ))
        credits.append(NSAttributedString(
            string: "\n\nFork of ZoomacIt by 07JP27 (GPL-3.0):\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        ))
        let originalURL = URL(string: "https://github.com/07JP27/ZoomacIt")!
        credits.append(NSAttributedString(
            string: "https://github.com/07JP27/ZoomacIt",
            attributes: [
                .link: originalURL,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        ))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .init(rawValue: "Copyright"): "© 2026 Josiah Coad"
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    /// Rebuild the menu to reflect updated hotkey settings.
    func rebuildMenu() {
        statusItem?.menu = buildMenu()
    }
}
