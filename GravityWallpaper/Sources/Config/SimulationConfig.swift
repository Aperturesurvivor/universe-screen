// Shared mutable config — all layers read this each frame so sliders take effect immediately.
import Foundation

final class SimulationConfig {

    // MARK: - Motion (purely kinematic)
    var motionAmount: Float = 1.0

    // MARK: - Star appearance (driven by NetworkMonitor; can be overridden by sliders)
    var starTemperature:  Float = 0.08   // 0 warm/orange ↔ 1 cool/blue
    var starIntensity:    Float = 0.85   // 0 dim ↔ 1 bright
    var starStability:    Float = 0.14   // 0 chaotic/turbulent ↔ 1 calm
    var starCoronaScale:  Float = 1.0    // 0.3 small halo ↔ 2.0 huge halo
    var starFlareDensity: Float = 0.30   // 0 no flares ↔ 1 many flares

    /// Called by NetworkMonitor on each path update. Updates star fields in-place
    /// so sliders always reflect the live values.
    func applyNetworkScores(temperature: Float, intensity: Float, stability: Float,
                            coronaScale: Float, flareDensity: Float) {
        starTemperature  = temperature
        starIntensity    = intensity
        starStability    = stability
        starCoronaScale  = coronaScale
        starFlareDensity = flareDensity
    }

    // MARK: - Gamified mode (window above icons vs below)
    var gamifiedMode: Bool = false

    // MARK: - Status (read-only mirror, set by AppDelegate)
    var planetCount: Int = 0
    var asteroidCount: Int = 0
    var positionSource: String = "auto"
}
