import SwiftUI
import ServiceManagement

/// The single settings tab: activation, cursor appearance, and gesture reference.
struct GeneralTab: View {

    @AppStorage(Settings.Keys.holdModifier) private var holdModifierRaw: String = ActivationModifier.option.rawValue
    @AppStorage(Settings.Keys.laserEnabled) private var laserEnabled: Bool = false
    @AppStorage(Settings.Keys.color) private var colorRaw: String = PenColor.red.rawValue

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var holdModifier: ActivationModifier { ActivationModifier(rawValue: holdModifierRaw) ?? .option }
    private var sym: String { holdModifier.symbol }

    private var holdModifierBinding: Binding<ActivationModifier> {
        Binding(
            get: { holdModifier },
            set: { holdModifierRaw = $0.rawValue }
        )
    }

    private var color: Binding<PenColor> {
        Binding(
            get: { PenColor(rawValue: colorRaw) ?? .red },
            set: { colorRaw = $0.rawValue }
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
                gestureRow("Toggle", "\(sym)Space")
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
        .onChange(of: holdModifierRaw) { _, _ in
            // The pin/unpin hotkey is <modifier>+Space, so re-register when it changes.
            HotkeyManager.shared.reregisterHotkeys()
        }
    }

    private func gestureRow(_ label: String, _ gesture: String) -> some View {
        HStack {
            Text(label)
                .frame(width: 110, alignment: .leading)
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
