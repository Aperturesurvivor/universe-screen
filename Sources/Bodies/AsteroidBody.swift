// Body — represents a desktop file (anything that isn't a folder).
import Foundation
import simd

struct AsteroidBody: CelestialBody {
    let stableId:  String
    let name:      String
    let actionURL: URL?

    var position:   SIMD3<Float>
    var radius:     Float
    var phase:      Float
    var variant:    UInt32      // for visual variation in the shader

    var kind: BodyKind { .asteroid }

    var gpu: AsteroidGPU {
        AsteroidGPU(position: position, radius: radius,
                    phase: phase, variant: variant)
    }
}

/// 32-byte stride; matches `AsteroidGPU` in asteroid.metal
struct AsteroidGPU {
    var position: SIMD3<Float>   // 16 (12 + 4 pad), offset 0
    var radius:   Float          // 4,               offset 16
    var phase:    Float          // 4,               offset 20
    var variant:  UInt32         // 4,               offset 24
    var _pad:     Float = 0      // 4,               offset 28 — to 32 stride
}

extension AsteroidBody {
    static func make(from file: FileInfo, screenSize: CGSize, seed: Seed) -> AsteroidBody {
        var rng = seed.rng(forBodyId: file.url.absoluteString)
        let position = Self.placement(for: file, screenSize: screenSize, rng: &rng)
        let radius   = Self.visualRadius(for: file.sizeBytes)
        return AsteroidBody(
            stableId:  file.url.absoluteString,
            name:      file.url.lastPathComponent,
            actionURL: file.url,
            position:  position,
            radius:    radius,
            phase:     rng.float(in: 0...(2 * .pi)),
            variant:   UInt32(rng.int(in: 0...2))
        )
    }

    private static func placement(for file: FileInfo, screenSize: CGSize,
                                   rng: inout SeededRandom) -> SIMD3<Float> {
        if let icon = file.iconPosition,
           screenSize.width > 1, screenSize.height > 1 {
            return SIMD3(Float(icon.x), 0, Float(icon.y))
        }
        // Fallback: scattered dots inside the screen
        return SIMD3(rng.float(in: 0...Float(screenSize.width)),
                     0,
                     rng.float(in: 0...Float(screenSize.height)))
    }

    private static func visualRadius(for bytes: Int64) -> Float {
        // Files top out smaller than folders so the visual hierarchy stays clear.
        let kb  = max(1.0, Double(bytes) / 1_024)
        let raw = Float(log10(kb + 1) * 2.5 + 6)
        return min(max(raw, 6), 18)
    }
}
