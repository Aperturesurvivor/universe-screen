// Body — the Trash → Black Hole.
// Singleton, like StarBody. Visual is intentionally simple: a black event-
// horizon sphere wrapped by a bright photon ring and a soft outer halo.
import Foundation
import simd

struct BlackHoleBody: CelestialBody {
    let stableId:  String = "blackhole"
    let name:      String
    let actionURL: URL?

    var position:  SIMD3<Float>
    var radius:    Float       // event horizon radius (also the hit-test target)
    var intensity: Float       // master brightness for ring + halo

    var kind: BodyKind { .blackHole }

    var gpu: BlackHoleGPU {
        BlackHoleGPU(
            position:  SIMD4(position, 1),
            radius:    radius,
            intensity: intensity)
    }
}

/// 32-byte stride; matches BlackHoleGPU in blackhole.metal.
struct BlackHoleGPU {
    var position:  SIMD4<Float>   // offset  0
    var radius:    Float          // offset 16
    var intensity: Float          // offset 20
    var _pad0:     Float = 0      // offset 24
    var _pad1:     Float = 0      // offset 28 → stride 32
}

extension BlackHoleBody {
    /// Builds the singleton black hole from current screen size.
    /// Positioned at the bottom-right of the viewport in world (= screen-point)
    /// space.
    static func make(screenSize: CGSize, seed: Seed) -> BlackHoleBody {
        let w = Float(screenSize.width)
        let h = Float(screenSize.height)

        // Bottom-right placement. World +X = right, world +Z = down on screen
        // (Camera.up is -Z), so "bottom right" is (high X, high Z).
        let position = SIMD3<Float>(w * 0.85, 0, h * 0.82)

        // Compact relative to the central star (radius ≈ minDim * 0.075).
        let minDim = Float(min(screenSize.width, screenSize.height))
        let radius = max(40, minDim * 0.045)

        // Trash directory; left-click in M2 will route here via NSWorkspace.open.
        let trashURL = (try? FileManager.default.url(for: .trashDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")

        return BlackHoleBody(
            name:      "Trash",
            actionURL: trashURL,
            position:  position,
            radius:    radius,
            intensity: 1.0)
    }
}
