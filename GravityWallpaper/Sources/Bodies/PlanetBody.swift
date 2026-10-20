// Body — represents a desktop folder. CPU-side carries name/URL; the GPU mirror
// (PlanetGPU) is what gets uploaded to the planet pipeline's instance buffer.
import Foundation
import simd

struct PlanetBody: CelestialBody {
    let stableId:  String
    let name:      String
    let actionURL: URL?

    var position:   SIMD3<Float>
    var radius:     Float
    var biomeIndex: UInt32
    var phase:      Float
    var spinSpeed:  Float

    // Orbital mechanics — set by Universe.update() after star center is known
    var orbitRadius:       Float = 0
    var targetOrbitRadius: Float = 0   // ground-state shell radius; orbitRadius lerps toward this
    var orbitAngle:        Float = 0   // radians, advances each frame
    var orbitSpeed:        Float = 0   // radians/second
    var shellIndex:        Int   = 0   // which electron shell this planet occupies

    var kind: BodyKind { .planet }

    var gpu: PlanetGPU {
        PlanetGPU(position: position, radius: radius,
                  phase: phase, biomeIndex: biomeIndex, spinSpeed: spinSpeed)
    }
}

/// 32-byte stride; matches `PlanetGPU` in render.metal
struct PlanetGPU {
    var position:   SIMD3<Float>   // 16 (12 + 4 pad), offset 0
    var radius:     Float          // 4,               offset 16
    var phase:      Float          // 4,               offset 20
    var biomeIndex: UInt32         // 4,               offset 24
    var spinSpeed:  Float          // 4,               offset 28
}

extension PlanetBody {
    /// Build a planet from a folder. Visual properties come from the seed
    /// so a given user always sees the same world.
    static func make(from folder: FolderInfo, screenSize: CGSize, seed: Seed) -> PlanetBody {
        var rng = seed.rng(forBodyId: folder.url.absoluteString)
        let position = Self.worldPosition(name: folder.name,
                                          iconPosition: folder.iconPosition,
                                          screenSize: screenSize)
        let radius   = Self.visualRadius(for: folder.sizeBytes)
        return PlanetBody(
            stableId:   folder.url.absoluteString,
            name:       folder.name,
            actionURL:  folder.url,
            position:   position,
            radius:     radius,
            biomeIndex: folder.biome.rawValue,
            phase:      rng.float(in: 0...(2 * .pi)),
            spinSpeed:  rng.float(in: 0.2...0.6)
        )
    }

    static func worldPosition(name: String,
                              iconPosition: CGPoint?,
                              screenSize: CGSize) -> SIMD3<Float> {
        let width = Float(screenSize.width)
        let height = Float(screenSize.height)
        let center = SIMD2<Float>(width * 0.5, height * 0.5)
        let minDim = Float(min(screenSize.width, screenSize.height))
        let h = stableHash64(name)

        let angleJitter = (Float((h >> 20) & 0x3FF) / 1023.0 - 0.5) * 0.42
        let radialJitter = (Float((h >> 32) & 0x3FF) / 1023.0 - 0.5) * minDim * 0.035

        let baseInner = minDim * 0.18
        let baseOuter = minDim * 0.34

        if let icon = iconPosition, width > 1, height > 1 {
            let iconVec = SIMD2<Float>(Float(icon.x), Float(icon.y)) - center
            let iconDist = simd_length(iconVec)
            let maxDist = max(minDim * 0.5, 1)
            let distNorm = min(iconDist / maxDist, 1.0)

            let baseAngle = atan2(iconVec.y, iconVec.x)
            let angle = baseAngle + angleJitter
            let radius = simd_mix(baseInner, baseOuter, 0.18 + distNorm * 0.82) + radialJitter
            return SIMD3(center.x + cos(angle) * radius * 1.10,
                         0,
                         center.y + sin(angle) * radius * 0.92)
        }

        // Deterministic fallback ring layout when Finder positions aren't available.
        let theta = Float(h & 0xFFFF) / 65535.0 * 2 * .pi + angleJitter
        let frac  = Float((h >> 16) & 0xFF) / 255.0
        let radius = simd_mix(baseInner, baseOuter, frac) + radialJitter
        return SIMD3(center.x + cos(theta) * radius * 1.10,
                     0,
                     center.y + sin(theta) * radius * 0.92)
    }

    private static func visualRadius(for bytes: Int64) -> Float {
        let mb  = max(1.0, Double(bytes) / 1_000_000)
        let raw = Float(log10(mb + 1) * 6 + 22)
        return min(max(raw, 22), 55)
    }

    /// Assign this planet to an electron-shell ring.
    /// `slotIndex` / `slotsInShell` evenly distributes planets around the ring.
    /// Each shell is phase-offset by 0.4 rad so adjacent shells look staggered.
    mutating func initOrbit(shellIndex: Int, slotIndex: Int, slotsInShell: Int,
                             starCenter: SIMD3<Float>, minDim: Float) {
        orbitRadius = Self.shellRadius(shellIndex: shellIndex, minDim: minDim)

        let shellPhase: Float = Float(shellIndex) * 0.4
        let slotAngle:  Float = slotsInShell > 1
            ? Float(slotIndex) * (2 * .pi / Float(slotsInShell))
            : 0
        orbitAngle = shellPhase + slotAngle

        position = SIMD3(
            starCenter.x + cos(orbitAngle) * orbitRadius,
            0,
            starCenter.z + sin(orbitAngle) * orbitRadius
        )

        let k: Float = 100
        orbitSpeed = k / pow(orbitRadius, 1.5)
    }

    /// Radius of shell `shellIndex` in world units (screen points).
    static func shellRadius(shellIndex: Int, minDim: Float) -> Float {
        let base: Float = max(100, minDim * 0.20)
        let step: Float = max(110, minDim * 0.18)
        return base + Float(shellIndex) * step
    }

    /// How many planets fit on shell `shellIndex` without looking crowded.
    /// Derived from ring circumference / (1.5 × max planet diameter).
    static func shellCapacity(shellIndex: Int, minDim: Float) -> Int {
        let r = shellRadius(shellIndex: shellIndex, minDim: minDim)
        return max(4, Int(2 * Float.pi * r / (110 * 1.5)))
    }

    /// Advance the orbital angle and recompute world position.
    /// Radius continuously lerps toward targetOrbitRadius (lowest-energy shell).
    mutating func advanceOrbit(deltaTime: Float, starCenter: SIMD3<Float>) {
        let lerpRate = 1 - exp(-deltaTime / 2.0)   // ~2 s time constant
        orbitRadius += (targetOrbitRadius - orbitRadius) * lerpRate
        orbitAngle  += orbitSpeed * deltaTime
        position = SIMD3(
            starCenter.x + cos(orbitAngle) * orbitRadius,
            0,
            starCenter.z + sin(orbitAngle) * orbitRadius
        )
    }
}
