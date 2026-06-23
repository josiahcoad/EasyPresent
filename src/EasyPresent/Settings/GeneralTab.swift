import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

/// The single settings tab: activation, appearance, and gesture reference.
struct GeneralTab: View {

    @AppStorage(Settings.Keys.holdModifier) private var holdModifierRaw: String = ActivationModifier.option.rawValue
    @AppStorage(Settings.Keys.toggleHotkeyKeyCode) private var toggleKeyCode: Int = Int(kVK_Space)
    @AppStorage(Settings.Keys.toggleHotkeyModifiers) private var toggleModifiers: Int = Int(optionKey)
    @AppStorage(Settings.Keys.disableInTextFields) private var disableInTextFields: Bool = false

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var holdModifier: ActivationModifier { ActivationModifier(rawValue: holdModifierRaw) ?? .option }
    private var sym: String { holdModifier.symbol }
    private var toggleStr: String {
        Settings.hotkeyDisplayString(keyCode: UInt32(toggleKeyCode), modifiers: UInt32(toggleModifiers))
    }

    private var holdModifierBinding: Binding<ActivationModifier> {
        Binding(get: { holdModifier }, set: { holdModifierRaw = $0.rawValue })
    }

    /// Turning this on prompts for Accessibility (needed to detect a focused text field).
    private var disableInTextFieldsBinding: Binding<Bool> {
        Binding(
            get: { disableInTextFields },
            set: { newValue in
                disableInTextFields = newValue
                if newValue {
                    (NSApp.delegate as? AppDelegate)?.requestTextFieldAccessibility()
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Activation") {
                Picker("Hold to draw", selection: holdModifierBinding) {
                    ForEach(ActivationModifier.allCases, id: \.self) { mod in
                        Text(mod.displayName).tag(mod)
                    }
                }
                HStack {
                    Text("Toggle shortcut")
                    Spacer()
                    KeyRecorderView(keyCode: $toggleKeyCode, modifiers: $toggleModifiers)
                        .frame(width: 140, height: 28)
                }
                Toggle("Don't activate in text fields", isOn: disableInTextFieldsBinding)
                Text("Keeps \(sym)←/→ word-jump working while typing. Needs Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gestures") {
                gestureRow("Draw", "\(sym) + drag")
                gestureRow("Box", "\(sym)⌘ + drag")
                gestureRow("Arrow", "\(sym)⇧ + drag")
                gestureRow("Toggle", toggleStr)
                gestureRow("Cycle color", "\(sym)↑ / \(sym)↓")
                gestureRow("Help", "⌥?")
                gestureRow("Preferences", "⌥,")
                gestureRow("Exit", "Release \(sym)")
            }

            Section {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                Button("Launch Onboarding") {
                    OnboardingCoordinator.shared.restart()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: holdModifierRaw) { _, _ in reregister() }
        .onChange(of: toggleKeyCode) { _, _ in reregister() }
        .onChange(of: toggleModifiers) { _, _ in reregister() }
    }

    private func reregister() {
        HotkeyManager.shared.reregisterHotkeys()
        NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
    }

    private func gestureRow(_ label: String, _ gesture: String) -> some View {
        HStack {
            Text(label)
                .frame(width: 130, alignment: .leading)
            Spacer()
            Text(gesture)
                .foregroundStyle(.secondary)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    launchAtLogin = newValue
                } catch {
                    NSLog("[GeneralTab] Failed to \(newValue ? "enable" : "disable") launch at login: \(error)")
                }
            }
        )
    }
}
