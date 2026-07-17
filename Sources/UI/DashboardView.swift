import SwiftUI

public struct DashboardView: View {
    @ObservedObject private var model: DashboardModel
    @State private var advancedExpanded = false

    public init(model: DashboardModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            DashboardBackdrop()

            ScrollView {
                VStack(spacing: 20) {
                    header

                    HStack(alignment: .top, spacing: 18) {
                        VStack(spacing: 16) {
                            sourceCard
                            metricsRow
                            integrationsCard
                        }
                        .frame(maxWidth: .infinity)

                        VStack(spacing: 16) {
                            modesCard
                            advancedCard
                        }
                        .frame(width: 300)
                    }
                }
                .padding(26)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 760, minHeight: 620)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white, DashboardPalette.sun, DashboardPalette.sun.opacity(0.12)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 30
                        )
                    )
                    .frame(width: 52, height: 52)
                    .shadow(color: DashboardPalette.sun.opacity(0.45), radius: 18)

                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.72))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("UNIVERSE SCREEN")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(DashboardPalette.mutedText)

                Text("Mission Control")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 16)

            StatusPill(state: model.overallState)

            Button(action: model.toggleUniverse) {
                Label(
                    model.isUniverseRunning ? "Hide Universe" : "Show Universe",
                    systemImage: model.isUniverseRunning ? "eye.slash.fill" : "play.fill"
                )
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(UniverseActionButtonStyle(active: model.isUniverseRunning))
            .disabled(model.rootURL == nil)
            .help(model.rootURL == nil ? "Choose a source folder first" : "Show or hide the live universe")
        }
    }

    private var sourceCard: some View {
        DashboardCard(title: "Source universe", symbol: "folder.badge.gearshape") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DashboardPalette.cyan.opacity(0.12))
                            .frame(width: 46, height: 46)

                        Image(systemName: "folder.fill")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(DashboardPalette.cyan)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.sourceName)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(model.sourceDisplayPath)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(DashboardPalette.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)
                }

                HStack(spacing: 10) {
                    Button(action: model.requestChooseSource) {
                        Label(model.rootURL == nil ? "Choose Folder" : "Change Folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(DashboardSecondaryButtonStyle())

                    Button(action: model.requestRevealSource) {
                        Label("Reveal", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(DashboardQuietButtonStyle())
                    .disabled(model.rootURL == nil)

                    Spacer()

                    Text("Immediate folders become project worlds")
                        .font(.system(size: 11))
                        .foregroundStyle(DashboardPalette.subtleText)
                        .lineLimit(1)
                }
            }
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 12) {
            MetricTile(
                value: model.folderCount,
                label: "Projects",
                symbol: "globe.americas.fill",
                tint: DashboardPalette.cyan
            )
            MetricTile(
                value: model.fileCount,
                label: "Files",
                symbol: "shippingbox.fill",
                tint: DashboardPalette.violet
            )
            MetricTile(
                value: model.activeAgentCount,
                label: "Active agents",
                symbol: "paperplane.fill",
                tint: DashboardPalette.sun
            )
        }
    }

    private var integrationsCard: some View {
        DashboardCard(title: "Live integrations", symbol: "wave.3.right.circle") {
            VStack(spacing: 0) {
                ConnectionRow(
                    title: "Filesystem",
                    detail: model.filesystemDetail,
                    symbol: "externaldrive.fill.badge.timemachine",
                    state: model.filesystemState
                )

                Divider()
                    .overlay(DashboardPalette.divider)
                    .padding(.leading, 42)

                ConnectionRow(
                    title: "Codex",
                    detail: model.codexDetail,
                    symbol: "point.3.connected.trianglepath.dotted",
                    state: model.codexState
                )

                if !model.agentNames.isEmpty {
                    Divider()
                        .overlay(DashboardPalette.divider)
                        .padding(.leading, 42)

                    HStack(spacing: 12) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DashboardPalette.sun)
                            .frame(width: 24)
                        Text("Fleet")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text(model.agentNames.prefix(4).joined(separator: "  ·  "))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(DashboardPalette.mutedText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 11)
                }
            }
        }
    }

    private var modesCard: some View {
        DashboardCard(title: "Universe modes", symbol: "switch.2") {
            VStack(spacing: 4) {
                DashboardToggleRow(
                    title: "Show Codex agents",
                    detail: "Render live work as spacecraft",
                    symbol: "paperplane",
                    isOn: binding(get: { model.showAgents }, set: { model.setShowAgents($0) })
                )

                DashboardToggleRow(
                    title: "Gamified Mode",
                    detail: "Place the universe above desktop icons",
                    symbol: "square.3.layers.3d",
                    isOn: binding(get: { model.gamifiedMode }, set: { model.setGamifiedMode($0) })
                )

                DashboardToggleRow(
                    title: "Privacy Mode",
                    detail: "Hide full source paths in Mission Control",
                    symbol: "eye.slash",
                    isOn: binding(get: { model.privacyMode }, set: { model.setPrivacyMode($0) })
                )

                DashboardToggleRow(
                    title: "Demo Mode",
                    detail: "Cinematic styling with live data",
                    symbol: "viewfinder",
                    isOn: binding(get: { model.demoMode }, set: { model.setDemoMode($0) })
                )
            }
        }
    }

    private var advancedCard: some View {
        DashboardCard {
            DisclosureGroup(isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 17) {
                    Divider().overlay(DashboardPalette.divider)

                    VStack(alignment: .leading, spacing: 8) {
                        DashboardFieldLabel("Appearance")
                        Picker("Appearance", selection: binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                            ForEach(DashboardAppearancePreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            DashboardFieldLabel("Render policy")
                            Spacer()
                            Text(model.measuredFPS > 0
                                 ? String(format: "%.1f fps measured", model.measuredFPS)
                                 : "Measuring…")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(DashboardPalette.green)
                        }
                        Picker("Render policy", selection: binding(get: { model.performanceMode }, set: { model.setPerformanceMode($0) })) {
                            ForEach(DashboardPerformanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            DashboardFieldLabel("Visible project worlds")
                            Text("Most recently active folders first")
                                .font(.system(size: 10))
                                .foregroundStyle(DashboardPalette.subtleText)
                        }
                        Spacer()
                        Stepper(
                            "\(model.worldLimit)",
                            value: binding(
                                get: { model.worldLimit },
                                set: { model.setWorldLimit($0) }),
                            in: 4...48,
                            step: 4)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .fixedSize()
                    }

                    DashboardSlider(
                        title: "Scene motion",
                        value: binding(get: { model.motionAmount }, set: { model.setMotionAmount($0) })
                    )

                    DashboardSlider(
                        title: "Ambient glow",
                        value: binding(get: { model.glowAmount }, set: { model.setGlowAmount($0) })
                    )
                }
                .padding(.top, 12)
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .tint(DashboardPalette.cyan)
        }
    }

    private func binding<Value: Sendable>(
        get: @escaping @MainActor @Sendable () -> Value,
        set: @escaping @MainActor @Sendable (Value) -> Void
    ) -> Binding<Value> {
        Binding(get: get, set: set)
    }
}

private enum DashboardPalette {
    static let cyan = Color(red: 0.34, green: 0.86, blue: 1.00)
    static let violet = Color(red: 0.63, green: 0.51, blue: 1.00)
    static let sun = Color(red: 1.00, green: 0.69, blue: 0.27)
    static let green = Color(red: 0.35, green: 0.91, blue: 0.62)
    static let warning = Color(red: 1.00, green: 0.55, blue: 0.30)
    static let mutedText = Color.white.opacity(0.64)
    static let subtleText = Color.white.opacity(0.42)
    static let divider = Color.white.opacity(0.08)
    static let cardFill = Color(red: 0.055, green: 0.075, blue: 0.13).opacity(0.88)
}

private struct DashboardBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.035, blue: 0.08),
                    Color(red: 0.035, green: 0.025, blue: 0.075),
                    Color(red: 0.018, green: 0.028, blue: 0.055)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(DashboardPalette.violet.opacity(0.13))
                .frame(width: 460, height: 460)
                .blur(radius: 90)
                .offset(x: 280, y: -240)

            Circle()
                .fill(DashboardPalette.cyan.opacity(0.08))
                .frame(width: 360, height: 360)
                .blur(radius: 100)
                .offset(x: -330, y: 270)
        }
        .ignoresSafeArea()
    }
}

private struct DashboardCard<Content: View>: View {
    private let title: String?
    private let symbol: String?
    @ViewBuilder private let content: Content

    init(
        title: String? = nil,
        symbol: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol)
                            .foregroundStyle(DashboardPalette.cyan)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            content
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DashboardPalette.cardFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.09), lineWidth: 1)
                }
        }
    }
}

private struct StatusPill: View {
    let state: DashboardConnectionState

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.65), radius: 5)
            Text(state.title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.065), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 1))
    }

    private var color: Color {
        switch state {
        case .disconnected: DashboardPalette.subtleText
        case .connecting:   DashboardPalette.sun
        case .live:         DashboardPalette.green
        case .attention:    DashboardPalette.warning
        }
    }
}

private struct MetricTile: View {
    let value: Int
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(value.formatted())
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(DashboardPalette.mutedText)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background(DashboardPalette.cardFill, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct ConnectionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let state: DashboardConnectionState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DashboardPalette.mutedText)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DashboardPalette.mutedText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            StatusPill(state: state)
        }
        .padding(.vertical, 11)
    }
}

private struct DashboardToggleRow: View {
    let title: String
    let detail: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? DashboardPalette.cyan : DashboardPalette.mutedText)
                .frame(width: 25)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardPalette.subtleText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DashboardPalette.cyan)
                .controlSize(.small)
        }
        .padding(.vertical, 9)
    }
}

private struct DashboardFieldLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1.15)
            .foregroundStyle(DashboardPalette.subtleText)
    }
}

private struct DashboardSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                DashboardFieldLabel(title)
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DashboardPalette.mutedText)
            }
            Slider(value: $value, in: 0...1)
                .tint(DashboardPalette.cyan)
        }
    }
}

private struct UniverseActionButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? DashboardPalette.cyan : Color.black.opacity(0.82))
            .background {
                Capsule()
                    .fill(active ? DashboardPalette.cyan.opacity(0.12) : DashboardPalette.cyan)
                    .overlay {
                        Capsule()
                            .stroke(DashboardPalette.cyan.opacity(active ? 0.4 : 0), lineWidth: 1)
                    }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct DashboardSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DashboardPalette.cyan.opacity(configuration.isPressed ? 0.20 : 0.13), in: Capsule())
            .overlay(Capsule().stroke(DashboardPalette.cyan.opacity(0.24), lineWidth: 1))
    }
}

private struct DashboardQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(DashboardPalette.mutedText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.09 : 0.05), in: Capsule())
    }
}
