// Body — the Internet Star.
// Colors come from the default browser as a 4-stop palette (core/mid/limb/accent).
// Real-time NWPath signals drive everything else:
//   intensity     — overall brightness / bloom strength
//   stability     — surface turbulence speed
//   coronaScale   — corona size + wispy detail amount
//   flareDensity  — looping prominence frequency
//   temperature   — subtle warm/cool tint
//   pulseRate     — gentle activity pulse
import Foundation
import simd

struct StarBody: CelestialBody {
    let stableId:  String = "star"
    let name:      String
    let actionURL: URL?

    var position: SIMD3<Float>
    var radius:   Float

    // 4-stop browser palette
    var coreColor:   SIMD3<Float>
    var midColor:    SIMD3<Float>
    var limbColor:   SIMD3<Float>
    var accentColor: SIMD3<Float>

    var pulseRate:    Float
    var intensity:    Float
    var phase:        Float
    var temperature:  Float
    var stability:    Float
    var coronaScale:  Float
    var flareDensity: Float
    var seed:         Float

    var kind: BodyKind { .star }

    var gpu: StarGPU {
        StarGPU(
            position:     SIMD4(position, 1),
            coreColor:    SIMD4(coreColor,   1),
            midColor:     SIMD4(midColor,    1),
            limbColor:    SIMD4(limbColor,   1),
            accentColor:  SIMD4(accentColor, 1),
            radius:       radius,
            pulseRate:    pulseRate,
            intensity:    intensity,
            phase:        phase,
            temperature:  temperature,
            stability:    stability,
            coronaScale:  coronaScale,
            flareDensity: flareDensity,
            seed:         seed)
    }
}

/// 128-byte stride; matches StarGPU in star.metal.
struct StarGPU {
    var position:     SIMD4<Float>   // offset   0
    var coreColor:    SIMD4<Float>   // offset  16
    var midColor:     SIMD4<Float>   // offset  32
    var limbColor:    SIMD4<Float>   // offset  48
    var accentColor:  SIMD4<Float>   // offset  64
    var radius:       Float          // offset  80
    var pulseRate:    Float          // offset  84
    var intensity:    Float          // offset  88
    var phase:        Float          // offset  92
    var temperature:  Float          // offset  96
    var stability:    Float          // offset 100
    var coronaScale:  Float          // offset 104
    var flareDensity: Float          // offset 108
    var seed:         Float          // offset 112
    var _pad0:        Float = 0      // offset 116
    var _pad1:        Float = 0      // offset 120
    var _pad2:        Float = 0      // offset 124 → stride 128
}

extension StarBody {
    static func make(browser: BrowserInfo,
                     isOnline: Bool,
                     temperature:  Float,
                     intensity:    Float,
                     stability:    Float,
                     coronaScale:  Float,
                     flareDensity: Float,
                     screenSize:   CGSize,
                     seed:         Seed) -> StarBody {
        var rng = seed.rng(forBodyId: "star")
        let center = SIMD3(Float(screenSize.width)  * 0.5,
                           0,
                           Float(screenSize.height) * 0.5)
        let radius = max(78, Float(min(screenSize.width, screenSize.height)) * 0.075)

        let pulseRate: Float = isOnline ? (0.72 + intensity * 0.55) : 0.34

        return StarBody(
            name:         browser.name,
            actionURL:    browser.url,
            position:     center,
            radius:       radius,
            coreColor:    browser.theme.core,
            midColor:     browser.theme.mid,
            limbColor:    browser.theme.limb,
            accentColor:  browser.theme.accent,
            pulseRate:    pulseRate,
            intensity:    max(0.72, min(1.18, 0.82 + intensity * 0.34)),
            phase:        rng.float(in: 0...(2 * .pi)),
            temperature:  temperature,
            stability:    stability,
            coronaScale:  max(0.95, coronaScale * 1.10),
            flareDensity: min(1.0, flareDensity * 1.08),
            seed:         rng.float(in: 0...1000))
    }
}
