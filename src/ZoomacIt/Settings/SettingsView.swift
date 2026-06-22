import SwiftUI

/// Root settings view with tabs for each configuration category.
struct SettingsView: View {

    @State private var showResetAlert = false

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralTab()
                    .tabItem { Text("General") }
                StatsTab()
                    .tabItem { Text("Stats") }
            }
            .frame(minWidth: 480, minHeight: 320)

            Divider()

            HStack {
                Button("Reset to Defaults") {
                    showResetAlert = true
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .padding()
        .alert("Reset to Defaults", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Settings.shared.resetToDefaults()
                HotkeyManager.shared.reregisterHotkeys()
            }
        } message: {
            Text("All settings will be restored to their default values. This cannot be undone.")
        }
    }
}

// MARK: - Stats

/// Read-only local usage counters.
struct StatsTab: View {
    private let stats = Settings.shared

    var body: some View {
        Form {
            Section("Usage") {
                statRow("Drawing sessions", stats.drawSessions)
                statRow("Boxes drawn", stats.boxesDrawn)
                statRow("Arrows drawn", stats.arrowsDrawn)
            }
            Section {
                Text("Counted locally on this Mac. Nothing is sent anywhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func statRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
