import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

/// A piece of a keyboard shortcut: either a key (rendered as a little keycap)
/// or surrounding text like " + drag" or "Release".
enum GestureToken {
    case key(String)
    case text(String)
}

/// Small info glyph that pops a tooltip the instant the cursor enters it
/// (SwiftUI's `.help()` waits ~1.5s, which feels broken in dense settings UIs).
struct InlineHelp: View {
    let text: String
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(2)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            // `.popover` renders in its own window above the Settings chrome,
            // so the tooltip escapes the Form section's clipping.
            .popover(isPresented: $isHovering) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
            }
    }
}

/// A small rounded keycap visual. Matches the look macOS uses inline in help text.
struct KeyChip: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .frame(minWidth: 18)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
            )
    }
}

/// The single settings tab: activation, appearance, and gesture reference.
struct GeneralTab: View {

    @AppStorage(Settings.Keys.holdModifier) private var holdModifierRaw: String = ActivationModifier.option.rawValue
    @AppStorage(Settings.Keys.toggleHotkeyKeyCode) private var toggleKeyCode: Int = Int(kVK_Space)
    @AppStorage(Settings.Keys.autoDisappearSeconds) private var autoDisappearSeconds: Double = 0

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var holdModifier: ActivationModifier { ActivationModifier(rawValue: holdModifierRaw) ?? .option }
    private var sym: String { holdModifier.symbol }
    private var toggleStr: String {
        // Toggle modifier is implicitly the base — only the character is configurable.
        Settings.hotkeyDisplayString(keyCode: UInt32(toggleKeyCode),
                                     modifiers: holdModifier.carbonFlag)
    }

    private var holdModifierBinding: Binding<ActivationModifier> {
        Binding(get: { holdModifier }, set: { holdModifierRaw = $0.rawValue })
    }

    var body: some View {
        Form {
            Section("Activation") {
                Picker("Base key", selection: holdModifierBinding) {
                    ForEach(ActivationModifier.allCases, id: \.self) { mod in
                        Text(mod.displayName).tag(mod)
                    }
                }
                HStack {
                    Text("Toggle")
                    Spacer()
                    BaseKeyRecorderView(keyCode: $toggleKeyCode, baseModifier: holdModifier)
                        .frame(width: 140, height: 28)
                }
            }

            Section("Shortcuts") {
                gestureRow("Toggle highlight", toggleTokens)
                gestureRow("Draw",             [.key(sym), .text("+ drag")])
                gestureRow("Box",              [.key(sym), .key("⌘"), .text("+ drag")])
                gestureRow("Arrow",            [.key(sym), .key("⇧"), .text("+ drag")])
                gestureRow("Clear screen",     [.key(sym), .key("E")])
                gestureRow("Undo",             [.key(sym), .key("Z")])
                gestureRow("Cycle color",      [.key(sym), .key("↑"), .text("/"), .key(sym), .key("↓")])
                gestureRow("Auto-clear time",  [.key(sym), .key("0–9")])
                gestureRow("Help",             [.key("⌥"), .key("?")])
                gestureRow("Preferences",      [.key("⌥"), .key(",")])
            }

            Section("Behavior") {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                // Tags cover the full ⌥0–9 hotkey range so any digit the user
                // presses lands on a visible option (was missing 4/6/7/8/9 →
                // the popup rendered blank when one of those was set).
                Picker(selection: $autoDisappearSeconds) {
                    Text("Off").tag(0.0)
                    ForEach(1...9, id: \.self) { n in
                        Text("\(n) second\(n == 1 ? "" : "s")").tag(Double(n))
                    }
                } label: {
                    labelWithInfo("Auto-clear drawings",
                                  "Notations fade out after you draw them. Set instantly with \(sym)0–9.")
                }
                Button("Restart onboarding") {
                    OnboardingCoordinator.shared.restart()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: holdModifierRaw) { _, _ in reregister() }
        .onChange(of: toggleKeyCode) { _, _ in reregister() }
    }

    private func reregister() {
        HotkeyManager.shared.reregisterHotkeys()
        NotificationCenter.default.post(name: .hotkeysDidChange, object: nil)
    }

    /// Label + a small info glyph whose tooltip pops instantly on hover.
    @ViewBuilder
    private func labelWithInfo(_ title: String, _ help: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
            InlineHelp(text: help)
        }
    }

    /// The toggle hotkey, broken into a sequence of chips: the implicit base
    /// modifier followed by the recorded character.
    private var toggleTokens: [GestureToken] {
        [.key(sym), .key(Settings.keyCodeToString(UInt32(toggleKeyCode)))]
    }

    private func gestureRow(_ label: String, _ tokens: [GestureToken]) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .frame(width: 130, alignment: .leading)
            Spacer()
            HStack(spacing: 4) {
                ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                    switch token {
                    case .key(let s):  KeyChip(s)
                    case .text(let s): Text(s).foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
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
