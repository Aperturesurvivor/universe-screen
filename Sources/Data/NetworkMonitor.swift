// Layer 1 — Data: NWPathMonitor wrapper.
// Exposes three independent star-driving signals:
//   • temperatureScore (0 warm ↔ 1 cool)   — connection type
//   • intensityScore   (0 dim  ↔ 1 bright) — bandwidth proxy
//   • stabilityScore   (0 chaotic ↔ 1 calm) — recent change frequency
// All three are hooked to NWPath today; can be swapped for real measurements
// (latency, throughput, error rate) without touching the renderer.
import Network
import Foundation

@MainActor
final class NetworkMonitor {

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "UniverseScreen.network")

    private(set) var isOnline:         Bool  = true
    private(set) var temperatureScore: Float = 0.08
    private(set) var intensityScore:   Float = 0.85
    private(set) var stabilityScore:   Float = 0.14
    /// Derived: 0.7 (offline) ↔ 1.20 (wired). Larger = bigger halo.
    var coronaScaleScore:  Float { 0.70 + intensityScore * 0.50 }
    /// Derived: 0.20 (very stable) ↔ 0.85 (very chaotic). Higher = more flares.
    var flareDensityScore: Float { 0.20 + (1.0 - stabilityScore) * 0.65 }

    private var changeTimes: [Date] = []
    private var onChange: () -> Void = {}

    func start(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            let scores = Self.scoresFor(path: path)
            DispatchQueue.main.async {
                guard let self else { return }

                // Track change frequency to derive stability.
                let now = Date()
                self.changeTimes.append(now)
                self.changeTimes = self.changeTimes.filter { now.timeIntervalSince($0) < 60 }
                let stability = max(0.04, 0.14 - Float(self.changeTimes.count - 1) * 0.03)

                let online    = scores.online
                let temp      = scores.temperature
                let intensity = scores.intensity
                let changed = (online != self.isOnline)
                           || abs(temp      - self.temperatureScore) > 0.01
                           || abs(intensity - self.intensityScore)   > 0.01
                           || abs(stability - self.stabilityScore)   > 0.01
                if changed {
                    self.isOnline         = online
                    self.temperatureScore = temp
                    self.intensityScore   = intensity
                    self.stabilityScore   = stability
                    self.onChange()
                }
            }
        }
        monitor.start(queue: queue)
    }

    private struct Scores {
        let online: Bool
        let temperature: Float
        let intensity: Float
    }

    nonisolated private static func scoresFor(path: NWPath) -> Scores {
        let online = (path.status == .satisfied)
        if !online {
            return Scores(online: false, temperature: 0.0, intensity: 0.30)
        }
        // Connection-type proxy. Real bandwidth measurement can replace this later.
        if path.usesInterfaceType(.wiredEthernet) {
            return Scores(online: true, temperature: 0.00, intensity: 1.00)
        }
        if path.usesInterfaceType(.wifi) && !path.isExpensive && !path.isConstrained {
            return Scores(online: true, temperature: 0.08, intensity: 0.90)
        }
        if path.usesInterfaceType(.wifi) {
            return Scores(online: true, temperature: 0.22, intensity: 0.70)
        }
        if path.usesInterfaceType(.cellular) {
            return Scores(online: true, temperature: 0.35, intensity: 0.55)
        }
        return Scores(online: true, temperature: 0.15, intensity: 0.75)
    }

    nonisolated deinit { /* monitor lives for app lifetime */ }
}
