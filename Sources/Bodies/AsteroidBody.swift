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
        let radius   = Self.visualRadius(for: file.sizeBytes)
        let position = Self.placement(
            for: file, screenSize: screenSize, radius: radius, rng: &rng)
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

    private static func placement(for file: FileInfo,
                                  screenSize: CGSize,
                                  radius: Float,
                                  rng: inout SeededRandom) -> SIMD3<Float> {
        if let icon = file.iconPosition,
           screenSize.width > 1, screenSize.height > 1 {
            return SIMD3(Float(icon.x), 0, Float(icon.y))
        }

        // Fallback sources have no Finder position to preserve. Scatter their
        // file bodies across the screen, but reserve the star's central disk so
        // a rock can never masquerade as a sunspot.
        let point = SIMD2(
            rng.float(in: 0...Float(screenSize.width)),
            rng.float(in: 0...Float(screenSize.height)))
        let center = SIMD2(
            Float(screenSize.width) * 0.5,
            Float(screenSize.height) * 0.5)
        let starRadius = max(78, Float(min(screenSize.width, screenSize.height)) * 0.075)
        let safeDistance = starRadius + radius + 12
        let delta = point - center
        let distance = simd_length(delta)

        guard distance < safeDistance else {
            return SIMD3(point.x, 0, point.y)
        }

        let direction: SIMD2<Float>
        if distance > 0.001 {
            direction = delta / distance
        } else {
            let hash = stableHash64(file.url.absoluteString)
            let angle = Float(hash & 0xFFFF) / 65535 * 2 * .pi
            direction = SIMD2(cos(angle), sin(angle))
        }
        let safePoint = center + direction * safeDistance
        return SIMD3(safePoint.x, 0, safePoint.y)
    }

    private static func visualRadius(for bytes: Int64) -> Float {
        // Files top out smaller than folders so the visual hierarchy stays clear.
        let kb  = max(1.0, Double(bytes) / 1_024)
        let raw = Float(log10(kb + 1) * 2.5 + 6)
        return min(max(raw, 6), 18)
    }
}
