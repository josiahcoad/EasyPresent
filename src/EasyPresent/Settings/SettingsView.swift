import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Root settings view with tabs for each configuration category.
struct SettingsView: View {

    @State private var showResetAlert = false

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Text("General") }
            AppearanceTab()
                .tabItem { Text("Appearance") }
            StatsTab()
                .tabItem { Text("Stats") }
        }
        .padding(.top, 12)                                     // clear the title bar
        .frame(minWidth: 520, minHeight: 500)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Reset to Defaults") {
                    showResetAlert = true
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 14)
            .background(.bar)
        }
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

// MARK: - Appearance

/// Halo + cursor appearance settings with a live preview at the top.
struct AppearanceTab: View {

    @AppStorage(Settings.Keys.color) private var colorRaw: String = PenColor.orange.rawValue
    @AppStorage(Settings.Keys.laserEnabled) private var laserEnabled: Bool = false
    @AppStorage(Settings.Keys.haloCenterStyle) private var centerRaw: String = HaloCenterStyle.none.rawValue
    @AppStorage(Settings.Keys.haloSize) private var haloSize: Double = 36
    @AppStorage(Settings.Keys.haloOuterRingEnabled) private var outerRing: Bool = true
    @AppStorage(Settings.Keys.haloContrastEnabled) private var contrastEnabled: Bool = true
    @AppStorage(Settings.Keys.haloGlowEnabled) private var glowEnabled: Bool = true
    @AppStorage(Settings.Keys.haloInfillStyle) private var infillRaw: String = HaloInfillStyle.border.rawValue
    @AppStorage(Settings.Keys.clickPulseEnabled) private var clickPulseEnabled: Bool = true
    @AppStorage(Settings.Keys.customColorHex) private var customColorHex: String = ""

    private var presetColor: PenColor { PenColor(rawValue: colorRaw) ?? .red }
    private var hasCustomColor: Bool { !customColorHex.isEmpty && NSColor(hexString: customColorHex) != nil }
    private var resolvedNSColor: NSColor {
        if hasCustomColor, let c = NSColor(hexString: customColorHex) { return c }
        return presetColor.nsColor
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hexString: customColorHex) ?? presetColor.nsColor) },
            set: { newValue in customColorHex = NSColor(newValue).hexString }
        )
    }

    private func selectPreset(_ c: PenColor) {
        colorRaw = c.rawValue
        customColorHex = ""
    }

    private var centerStyle: Binding<HaloCenterStyle> {
        Binding(get: { HaloCenterStyle(rawValue: centerRaw) ?? .plus }, set: { centerRaw = $0.rawValue })
    }

    private var infillStyle: Binding<HaloInfillStyle> {
        Binding(get: { HaloInfillStyle(rawValue: infillRaw) ?? .filled }, set: { infillRaw = $0.rawValue })
    }

    static let haloSizeSteps: [Double] = [28, 36, 42, 56]
    static let haloSizeLabels: [String] = ["S", "M", "L", "XL"]

    private var currentHaloSizeIndex: Int {
        Self.haloSizeSteps.enumerated().min { lhs, rhs in
            abs(lhs.element - haloSize) < abs(rhs.element - haloSize)
        }?.offset ?? 1
    }

    private var haloSizeIndexBinding: Binding<Double> {
        Binding(
            get: { Double(currentHaloSizeIndex) },
            set: { newIndex in
                let i = max(0, min(Self.haloSizeSteps.count - 1, Int(newIndex.rounded())))
                haloSize = Self.haloSizeSteps[i]
            }
        )
    }

    var body: some View {
        Form {
            Section("Preview") {
                HaloPreview(
                    color: resolvedNSColor,
                    radius: CGFloat(haloSize),
                    outerRingEnabled: outerRing,
                    centerStyle: HaloCenterStyle(rawValue: centerRaw) ?? .plus,
                    contrastEnabled: contrastEnabled,
                    glowEnabled: glowEnabled,
                    infillStyle: HaloInfillStyle(rawValue: infillRaw) ?? .filled
                )
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }

            Section("Cursor") {
                HStack(spacing: 10) {
                    Text("Color")
                    Spacer()
                    ForEach(PenColor.allCases, id: \.self) { c in
                        ColorSwatch(
                            color: c.nsColor,
                            selected: !hasCustomColor && c == presetColor,
                            action: { selectPreset(c) }
                        )
                    }
                    CustomColorWell(
                        selection: customColorBinding,
                        active: hasCustomColor,
                        displayColor: hasCustomColor
                            ? Color(nsColor: NSColor(hexString: customColorHex) ?? .gray)
                            : Color.gray.opacity(0.5)
                    )
                }

                Picker("Center", selection: centerStyle) {
                    ForEach(HaloCenterStyle.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }

                Toggle("Outer ring", isOn: $outerRing)

                Picker("Infill", selection: infillStyle) {
                    ForEach(HaloInfillStyle.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }

                Toggle("Glow", isOn: $glowEnabled)
                    .disabled(!outerRing)

                Toggle("Contrast outline", isOn: $contrastEnabled)
                    .disabled(!outerRing)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Ring size")
                        Spacer()
                        Text(Self.haloSizeLabels[currentHaloSizeIndex])
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: haloSizeIndexBinding,
                           in: 0...Double(Self.haloSizeSteps.count - 1),
                           step: 1)
                }
            }

            Section("Effects") {
                Toggle("Trailing laser", isOn: $laserEnabled)
                Toggle("Animate clicks", isOn: $clickPulseEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

/// Subtle tactile press feedback for clickable swatches.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Tappable color circle used in the swatch row.
struct ColorSwatch: View {
    let color: NSColor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .stroke(Color.accentColor, lineWidth: selected ? 2.5 : 0)
                        .padding(-3)
                        .animation(.easeOut(duration: 0.15), value: selected)
                )
                .frame(width: 32, height: 32)        // larger hit area
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// Circle-styled color well that matches the preset swatches. Visually shows the
/// active custom color (or grey if none), with a pencil glyph to hint editability.
/// Clicks go through to a hidden native ColorPicker behind it, which opens the
/// system color panel.
struct CustomColorWell: View {
    let selection: Binding<Color>
    let active: Bool
    let displayColor: Color

    var body: some View {
        ZStack {
            ColorPicker("", selection: selection, supportsOpacity: false)
                .labelsHidden()
                .opacity(0.011) // invisible but still receives clicks
                .frame(width: 32, height: 32)

            Circle()
                .fill(displayColor)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.35), radius: 0.5, y: 0.5)
                        .offset(y: -0.5) // optical: pencil's visual weight sits low
                )
                .overlay(
                    Circle()
                        .stroke(Color.accentColor, lineWidth: active ? 2.5 : 0)
                        .padding(-3)
                        .animation(.easeOut(duration: 0.15), value: active)
                )
                .allowsHitTesting(false)
        }
        .frame(width: 32, height: 32)
    }
}

/// Live, AppKit-backed preview of the halo as it would appear on a desktop.
struct HaloPreview: NSViewRepresentable {
    let color: NSColor
    let radius: CGFloat
    let outerRingEnabled: Bool
    let centerStyle: HaloCenterStyle
    let contrastEnabled: Bool
    let glowEnabled: Bool
    let infillStyle: HaloInfillStyle

    func makeNSView(context: Context) -> HaloPreviewNSView {
        HaloPreviewNSView()
    }

    func updateNSView(_ nsView: HaloPreviewNSView, context: Context) {
        nsView.color = color
        nsView.radius = radius
        nsView.outerRingEnabled = outerRingEnabled
        nsView.centerStyle = centerStyle
        nsView.contrastEnabled = contrastEnabled
        nsView.glowEnabled = glowEnabled
        nsView.infillStyle = infillStyle
        nsView.needsDisplay = true
    }
}

final class HaloPreviewNSView: NSView {
    var color: NSColor = .systemRed
    var radius: CGFloat = 22
    var outerRingEnabled: Bool = true
    var centerStyle: HaloCenterStyle = .plus
    var contrastEnabled: Bool = true
    var glowEnabled: Bool = false
    var infillStyle: HaloInfillStyle = .filled

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Checkerboard so the alpha glow is visible against a representative desktop.
        let tile: CGFloat = 12
        let cols = Int(ceil(bounds.width / tile))
        let rows = Int(ceil(bounds.height / tile))
        for r in 0..<rows {
            for c in 0..<cols {
                let dark = (r + c) % 2 == 0
                ctx.setFillColor((dark ? NSColor(white: 0.22, alpha: 1)
                                       : NSColor(white: 0.28, alpha: 1)).cgColor)
                ctx.fill(CGRect(x: CGFloat(c) * tile, y: CGFloat(r) * tile,
                                width: tile, height: tile))
            }
        }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        DrawingCanvasView.drawHalo(
            in: ctx,
            at: center,
            color: color,
            radius: radius,
            outerRingEnabled: outerRingEnabled,
            centerStyle: centerStyle,
            contrastEnabled: contrastEnabled,
            glowEnabled: glowEnabled,
            infillStyle: infillStyle
        )
    }
}
