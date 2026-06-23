import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

/// The single settings tab: activation, appearance, and gesture reference.
struct GeneralTab: View {

    @AppStorage(Settings.Keys.holdModifier) private var holdModifierRaw: String = ActivationModifier.option.rawValue
    @AppStorage(Settings.Keys.laserEnabled) private var laserEnabled: Bool = false
    @AppStorage(Settings.Keys.color) private var colorRaw: String = PenColor.red.rawValue
    @AppStorage(Settings.Keys.toggleHotkeyKeyCode) private var toggleKeyCode: Int = Int(kVK_Space)
    @AppStorage(Settings.Keys.toggleHotkeyModifiers) private var toggleModifiers: Int = Int(optionKey)

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var holdModifier: ActivationModifier { ActivationModifier(rawValue: holdModifierRaw) ?? .option }
    private var sym: String { holdModifier.symbol }
    private var toggleStr: String {
        Settings.hotkeyDisplayString(keyCode: UInt32(toggleKeyCode), modifiers: UInt32(toggleModifiers))
    }

    private var holdModifierBinding: Binding<ActivationModifier> {
        Binding(get: { holdModifier }, set: { holdModifierRaw = $0.rawValue })
    }

    private var color: Binding<PenColor> {
        Binding(get: { PenColor(rawValue: colorRaw) ?? .red }, set: { colorRaw = $0.rawValue })
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
                    Text("Pin / unpin shortcut")
                    Spacer()
                    KeyRecorderView(keyCode: $toggleKeyCode, modifiers: $toggleModifiers)
                        .frame(width: 140, height: 28)
                }
            }

            Section("Appearance") {
                Picker("Color", selection: color) {
                    ForEach(PenColor.allCases, id: \.self) { c in
                        HStack {
                            Circle()
                                .fill(Color(nsColor: c.nsColor))
                                .frame(width: 12, height: 12)
                            Text(c.rawValue.capitalized)
                        }
                        .tag(c)
                    }
                }
                Toggle("Trailing laser", isOn: $laserEnabled)
            }

            Section("Gestures") {
                gestureRow("Box", "\(sym) + drag")
                gestureRow("Arrow", "\(sym)⇧ + drag")
                gestureRow("Pin / unpin", toggleStr)
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
