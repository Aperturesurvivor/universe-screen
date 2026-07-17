// Shared observable configuration for the renderer, menu popover, and mission control.
// Settings that define the workspace experience persist between launches; live status does not.
import Combine
import Foundation

@MainActor
final class SimulationConfig: ObservableObject {

    private enum Key {
        static let sourcePath = "universe.sourcePath"
        static let maxWorlds = "universe.maxWorlds"
        static let showCodexAgents = "universe.showCodexAgents"
        static let privacyMode = "universe.privacyMode"
        static let targetFPS = "universe.targetFPS"
        static let motionAmount = "universe.motionAmount"
        static let gamifiedMode = "universe.gamifiedMode"
    }

    private let defaults: UserDefaults

    // MARK: - Workspace

    @Published var sourceURL: URL {
        didSet { defaults.set(sourceURL.path, forKey: Key.sourcePath) }
    }

    @Published var maxWorlds: Int {
        didSet {
            defaults.set(maxWorlds, forKey: Key.maxWorlds)
        }
    }

    @Published var showCodexAgents: Bool {
        didSet { defaults.set(showCodexAgents, forKey: Key.showCodexAgents) }
    }

    /// Hides full paths and any user-authored Codex text from the UI. Telemetry is
    /// metadata-only regardless of this setting; privacy mode controls presentation.
    @Published var privacyMode: Bool {
        didSet { defaults.set(privacyMode, forKey: Key.privacyMode) }
    }

    // MARK: - Motion and rendering

    @Published var motionAmount: Float {
        didSet { defaults.set(Double(motionAmount), forKey: Key.motionAmount) }
    }

    @Published var targetFPS: Int {
        didSet {
            defaults.set(targetFPS, forKey: Key.targetFPS)
        }
    }

    // MARK: - Star appearance (driven by NetworkMonitor; sliders can override)

    @Published var starTemperature:  Float = 0.08
    @Published var starIntensity:    Float = 0.85
    @Published var starStability:    Float = 0.14
    @Published var starCoronaScale:  Float = 1.0
    @Published var starFlareDensity: Float = 0.30

    func applyNetworkScores(temperature: Float, intensity: Float, stability: Float,
                            coronaScale: Float, flareDensity: Float) {
        starTemperature  = temperature
        starIntensity    = intensity
        starStability    = stability
        starCoronaScale  = coronaScale
        starFlareDensity = flareDensity
    }

    // MARK: - Window state

    @Published var gamifiedMode: Bool {
        didSet { defaults.set(gamifiedMode, forKey: Key.gamifiedMode) }
    }
    @Published var universeVisible = true

    // MARK: - Live status (set by AppDelegate)

    @Published var planetCount = 0
    @Published var asteroidCount = 0
    @Published var activeAgentCount = 0
    @Published var positionSource = "auto"
    @Published var filesystemLive = false
    @Published var codexLive = false
    @Published var measuredFPS: Double = 0
    @Published var projectNames: [String] = []
    @Published var agentSummaries: [String] = []

    var displaySourcePath: String {
        privacyMode ? sourceURL.lastPathComponent : sourceURL.path
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let fallback = Self.defaultSourceURL()
        if let path = defaults.string(forKey: Key.sourcePath),
           FileManager.default.fileExists(atPath: path) {
            sourceURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            sourceURL = fallback
        }

        let storedMax = defaults.integer(forKey: Key.maxWorlds)
        maxWorlds = storedMax == 0 ? 24 : min(48, max(4, storedMax))
        showCodexAgents = defaults.object(forKey: Key.showCodexAgents) == nil
            ? true : defaults.bool(forKey: Key.showCodexAgents)
        privacyMode = defaults.object(forKey: Key.privacyMode) == nil
            ? true : defaults.bool(forKey: Key.privacyMode)
        let storedFPS = defaults.integer(forKey: Key.targetFPS)
        targetFPS = storedFPS >= 60 ? 60 : 30
        let storedMotion = defaults.object(forKey: Key.motionAmount) as? Double
        motionAmount = Float(storedMotion ?? 1.0)
        gamifiedMode = defaults.bool(forKey: Key.gamifiedMode)
    }

    private static func defaultSourceURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectWorkspace = home
            .appendingPathComponent("Josiah", isDirectory: true)
            .appendingPathComponent("Project-Workspace", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: projectWorkspace.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return projectWorkspace
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? home
    }
}
