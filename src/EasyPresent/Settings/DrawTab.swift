import SwiftUI

/// Draw settings for the presenter overlay (halo + laser + box).
struct DrawTab: View {

    @AppStorage(Settings.Keys.defaultPenWidth) private var penWidth: Double = 3.0
    @AppStorage(Settings.Keys.laserEnabled) private var laserEnabled: Bool = true
    @AppStorage(Settings.Keys.haloColor) private var haloColorRaw: String = PenColor.yellow.rawValue

    private var haloColor: Binding<PenColor> {
        Binding(
            get: { PenColor(rawValue: haloColorRaw) ?? .yellow },
            set: { haloColorRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Cursor") {
                Picker("Halo Color", selection: haloColor) {
                    ForEach(PenColor.allCases, id: \.self) { color in
                        HStack {
                            Circle()
                                .fill(Color(nsColor: color.nsColor))
                                .frame(width: 12, height: 12)
                            Text(color.rawValue.capitalized)
                        }
                        .tag(color)
                    }
                }
                Toggle("Trailing laser", isOn: $laserEnabled)
            }

            Section("Box") {
                HStack {
                    Text("Line Width")
                    Slider(value: $penWidth, in: 1...50, step: 1)
                    Text("\(Int(penWidth)) pt")
                        .frame(width: 40, alignment: .trailing)
                        .monospacedDigit()
                }
            }

            Section("Controls") {
                controlRow("Hold ⌥ + move", "Show the halo + laser pointer")
                controlRow("⌥ + drag", "Draw a box")
                controlRow("Hold ⌥, tap Space", "Pin it on — release ⌥ and it stays")
                controlRow("⌥Space again", "Turn it off")
                controlRow("⌘Z", "Undo the last box")
                controlRow("Esc", "Exit draw mode")
            }
        }
        .formStyle(.grouped)
    }

    private func controlRow(_ gesture: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(gesture)
                .font(.system(.body, design: .monospaced))
                .frame(width: 150, alignment: .leading)
            Text(description)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
