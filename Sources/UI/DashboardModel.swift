import Foundation
import Combine

/// Connection health supplied by the filesystem and Codex integrations.
public enum DashboardConnectionState: String, CaseIterable, Identifiable, Sendable {
    case disconnected
    case connecting
    case live
    case attention

    public var id: Self { self }

    public var title: String {
        switch self {
        case .disconnected: "Offline"
        case .connecting:   "Connecting"
        case .live:         "Live"
        case .attention:    "Needs attention"
        }
    }
}

/// A deliberately small set of visual directions for the live universe.
public enum DashboardAppearancePreset: String, CaseIterable, Identifiable, Sendable {
    case natural
    case cinematic
    case minimal

    public var id: Self { self }

    public var title: String {
        switch self {
        case .natural:   "Natural"
        case .cinematic: "Cinematic"
        case .minimal:   "Minimal"
        }
    }
}

/// Render policy, intentionally expressed without an unmeasured frame-rate claim.
public enum DashboardPerformanceMode: String, CaseIterable, Identifiable, Sendable {
    case adaptive
    case fidelity
    case efficient

    public var id: Self { self }

    public var title: String {
        switch self {
        case .adaptive:  "Adaptive"
        case .fidelity:  "Fidelity"
        case .efficient: "Efficient"
        }
    }
}

/// Host hooks for connecting the dashboard to scanning, telemetry, and rendering.
/// Every callback is invoked on the main actor.
public struct DashboardCallbacks {
    public var onChooseSource: (() -> Void)?
    public var onSourceChanged: ((URL) -> Void)?
    public var onRevealSource: ((URL) -> Void)?
    public var onEnterUniverse: (() -> Void)?
    public var onExitUniverse: (() -> Void)?
    public var onPrivacyModeChanged: ((Bool) -> Void)?
    public var onShowAgentsChanged: ((Bool) -> Void)?
    public var onGamifiedModeChanged: ((Bool) -> Void)?
    public var onDemoModeChanged: ((Bool) -> Void)?
    public var onAppearanceChanged: ((DashboardAppearancePreset) -> Void)?
    public var onPerformanceModeChanged: ((DashboardPerformanceMode) -> Void)?
    public var onMotionAmountChanged: ((Double) -> Void)?
    public var onGlowAmountChanged: ((Double) -> Void)?
    public var onWorldLimitChanged: ((Int) -> Void)?

    public init(
        onChooseSource: (() -> Void)? = nil,
        onSourceChanged: ((URL) -> Void)? = nil,
        onRevealSource: ((URL) -> Void)? = nil,
        onEnterUniverse: (() -> Void)? = nil,
        onExitUniverse: (() -> Void)? = nil,
        onPrivacyModeChanged: ((Bool) -> Void)? = nil,
        onShowAgentsChanged: ((Bool) -> Void)? = nil,
        onGamifiedModeChanged: ((Bool) -> Void)? = nil,
        onDemoModeChanged: ((Bool) -> Void)? = nil,
        onAppearanceChanged: ((DashboardAppearancePreset) -> Void)? = nil,
        onPerformanceModeChanged: ((DashboardPerformanceMode) -> Void)? = nil,
        onMotionAmountChanged: ((Double) -> Void)? = nil,
        onGlowAmountChanged: ((Double) -> Void)? = nil,
        onWorldLimitChanged: ((Int) -> Void)? = nil
    ) {
        self.onChooseSource = onChooseSource
        self.onSourceChanged = onSourceChanged
        self.onRevealSource = onRevealSource
        self.onEnterUniverse = onEnterUniverse
        self.onExitUniverse = onExitUniverse
        self.onPrivacyModeChanged = onPrivacyModeChanged
        self.onShowAgentsChanged = onShowAgentsChanged
        self.onGamifiedModeChanged = onGamifiedModeChanged
        self.onDemoModeChanged = onDemoModeChanged
        self.onAppearanceChanged = onAppearanceChanged
        self.onPerformanceModeChanged = onPerformanceModeChanged
        self.onMotionAmountChanged = onMotionAmountChanged
        self.onGlowAmountChanged = onGlowAmountChanged
        self.onWorldLimitChanged = onWorldLimitChanged
    }
}

/// Observable dashboard state. Integrations can update the published properties
/// directly, or use the grouped update methods below for concise call sites.
@MainActor
public final class DashboardModel: ObservableObject {
    @Published public private(set) var rootURL: URL?
    @Published public private(set) var isUniverseRunning: Bool

    @Published public private(set) var filesystemState: DashboardConnectionState
    @Published public private(set) var codexState: DashboardConnectionState
    @Published public private(set) var filesystemDetail: String
    @Published public private(set) var codexDetail: String

    @Published public private(set) var folderCount: Int
    @Published public private(set) var fileCount: Int
    @Published public private(set) var activeAgentCount: Int

    @Published public private(set) var privacyMode: Bool
    @Published public private(set) var showAgents: Bool
    @Published public private(set) var gamifiedMode: Bool
    @Published public private(set) var demoMode: Bool

    @Published public private(set) var appearance: DashboardAppearancePreset
    @Published public private(set) var performanceMode: DashboardPerformanceMode
    @Published public private(set) var motionAmount: Double
    @Published public private(set) var glowAmount: Double
    @Published public private(set) var worldLimit: Int
    @Published public private(set) var measuredFPS: Double
    @Published public private(set) var agentNames: [String]

    public var callbacks: DashboardCallbacks

    public init(
        rootURL: URL? = nil,
        isUniverseRunning: Bool = false,
        filesystemState: DashboardConnectionState = .disconnected,
        codexState: DashboardConnectionState = .disconnected,
        filesystemDetail: String = "Choose a folder to begin watching",
        codexDetail: String = "Waiting for Codex telemetry",
        folderCount: Int = 0,
        fileCount: Int = 0,
        activeAgentCount: Int = 0,
        privacyMode: Bool = true,
        showAgents: Bool = true,
        gamifiedMode: Bool = false,
        demoMode: Bool = false,
        appearance: DashboardAppearancePreset = .natural,
        performanceMode: DashboardPerformanceMode = .adaptive,
        motionAmount: Double = 0.65,
        glowAmount: Double = 0.72,
        worldLimit: Int = 24,
        measuredFPS: Double = 0,
        agentNames: [String] = [],
        callbacks: DashboardCallbacks = DashboardCallbacks()
    ) {
        self.rootURL = rootURL
        self.isUniverseRunning = isUniverseRunning
        self.filesystemState = filesystemState
        self.codexState = codexState
        self.filesystemDetail = filesystemDetail
        self.codexDetail = codexDetail
        self.folderCount = max(0, folderCount)
        self.fileCount = max(0, fileCount)
        self.activeAgentCount = max(0, activeAgentCount)
        self.privacyMode = privacyMode
        self.showAgents = showAgents
        self.gamifiedMode = gamifiedMode
        self.demoMode = demoMode
        self.appearance = appearance
        self.performanceMode = performanceMode
        self.motionAmount = Self.clampUnit(motionAmount)
        self.glowAmount = Self.clampUnit(glowAmount)
        self.worldLimit = min(48, max(4, worldLimit))
        self.measuredFPS = max(0, measuredFPS)
        self.agentNames = Array(agentNames.prefix(8))
        self.callbacks = callbacks
    }

    public var sourceName: String {
        guard let name = rootURL?.lastPathComponent, !name.isEmpty else {
            return "No source selected"
        }
        return name
    }

    public var sourceDisplayPath: String {
        guard let rootURL else { return "Choose a folder containing your project worlds" }
        if privacyMode { return "Full path hidden" }
        return rootURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~", options: .anchored)
    }

    public var overallState: DashboardConnectionState {
        if filesystemState == .attention || codexState == .attention { return .attention }
        if filesystemState == .connecting || codexState == .connecting { return .connecting }
        if filesystemState == .live { return .live }
        return .disconnected
    }

    public func requestChooseSource() {
        callbacks.onChooseSource?()
    }

    public func requestRevealSource() {
        guard let rootURL else { return }
        callbacks.onRevealSource?(rootURL)
    }

    public func setRootURL(_ url: URL?, notify: Bool = false) {
        rootURL = url?.standardizedFileURL
        if notify, let rootURL { callbacks.onSourceChanged?(rootURL) }
    }

    public func setUniverseRunning(_ running: Bool, notify: Bool = false) {
        guard isUniverseRunning != running else { return }
        isUniverseRunning = running
        guard notify else { return }
        if running { callbacks.onEnterUniverse?() }
        else { callbacks.onExitUniverse?() }
    }

    public func toggleUniverse() {
        setUniverseRunning(!isUniverseRunning, notify: true)
    }

    public func updateConnections(
        filesystem: DashboardConnectionState,
        filesystemDetail: String? = nil,
        codex: DashboardConnectionState,
        codexDetail: String? = nil
    ) {
        filesystemState = filesystem
        codexState = codex
        if let filesystemDetail { self.filesystemDetail = filesystemDetail }
        if let codexDetail { self.codexDetail = codexDetail }
    }

    public func setFilesystemState(
        _ state: DashboardConnectionState,
        detail: String? = nil
    ) {
        filesystemState = state
        if let detail { filesystemDetail = detail }
    }

    public func setCodexState(
        _ state: DashboardConnectionState,
        detail: String? = nil
    ) {
        codexState = state
        if let detail { codexDetail = detail }
    }

    public func updateMetrics(folders: Int, files: Int, activeAgents: Int) {
        folderCount = max(0, folders)
        fileCount = max(0, files)
        activeAgentCount = max(0, activeAgents)
    }

    public func setPrivacyMode(_ enabled: Bool, notify: Bool = true) {
        guard privacyMode != enabled else { return }
        privacyMode = enabled
        if notify { callbacks.onPrivacyModeChanged?(enabled) }
    }

    public func setShowAgents(_ enabled: Bool, notify: Bool = true) {
        guard showAgents != enabled else { return }
        showAgents = enabled
        if notify { callbacks.onShowAgentsChanged?(enabled) }
    }

    public func setGamifiedMode(_ enabled: Bool, notify: Bool = true) {
        guard gamifiedMode != enabled else { return }
        gamifiedMode = enabled
        if notify { callbacks.onGamifiedModeChanged?(enabled) }
    }

    public func setDemoMode(_ enabled: Bool, notify: Bool = true) {
        guard demoMode != enabled else { return }
        demoMode = enabled
        if notify { callbacks.onDemoModeChanged?(enabled) }
    }

    public func setAppearance(_ preset: DashboardAppearancePreset, notify: Bool = true) {
        guard appearance != preset else { return }
        appearance = preset
        if notify { callbacks.onAppearanceChanged?(preset) }
    }

    public func setPerformanceMode(_ mode: DashboardPerformanceMode, notify: Bool = true) {
        guard performanceMode != mode else { return }
        performanceMode = mode
        if notify { callbacks.onPerformanceModeChanged?(mode) }
    }

    public func setMotionAmount(_ value: Double, notify: Bool = true) {
        let value = Self.clampUnit(value)
        guard motionAmount != value else { return }
        motionAmount = value
        if notify { callbacks.onMotionAmountChanged?(value) }
    }

    public func setGlowAmount(_ value: Double, notify: Bool = true) {
        let value = Self.clampUnit(value)
        guard glowAmount != value else { return }
        glowAmount = value
        if notify { callbacks.onGlowAmountChanged?(value) }
    }

    public func setWorldLimit(_ value: Int, notify: Bool = true) {
        let value = min(48, max(4, value))
        guard worldLimit != value else { return }
        worldLimit = value
        if notify { callbacks.onWorldLimitChanged?(value) }
    }

    public func setMeasuredFPS(_ value: Double) {
        measuredFPS = value.isFinite ? max(0, value) : 0
    }

    public func setAgentNames(_ names: [String]) {
        agentNames = Array(names.prefix(8))
    }

    private static func clampUnit(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
