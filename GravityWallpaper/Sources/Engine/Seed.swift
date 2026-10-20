// Engine — deterministic, shareable per-user seed + xorshift64 RNG.
// One seed per user is generated on first launch and stored in UserDefaults.
// Each celestial body gets its own RNG derived from `(universeSeed ^ stableHash(bodyId))`
// so rolling visual properties are reproducible across launches.
import Foundation

struct Seed: Equatable, Codable {
    let value: UInt64

    static func random() -> Seed {
        Seed(value: UInt64.random(in: 1...UInt64.max))
    }

    /// Stable per-body RNG.
    func rng(forBodyId id: String) -> SeededRandom {
        SeededRandom(state: value &+ stableHash64(id))
    }

    // MARK: - Persistence

    static let userDefaultsKey = "universeSeed"

    static func loadOrGenerate() -> Seed {
        if let v = UserDefaults.standard.object(forKey: userDefaultsKey) as? Int64 {
            return Seed(value: UInt64(bitPattern: v))
        }
        let s = Seed.random()
        s.save()
        return s
    }

    func save() {
        UserDefaults.standard.set(Int64(bitPattern: value), forKey: Seed.userDefaultsKey)
    }

    /// Human-shareable form: "u-7F3A9B…". Lets users paste a seed they found online.
    var displayString: String {
        "u-" + String(value, radix: 16, uppercase: true)
    }

    static func parse(_ s: String) -> Seed? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("u-") { t.removeFirst(2) }
        guard let v = UInt64(t, radix: 16) else { return nil }
        return Seed(value: v)
    }
}

/// Lightweight, deterministic xorshift64. Not cryptographic — perfect for procgen.
struct SeededRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        // Avoid the zero fixed point
        if state == 0 { state = 0x9E37_79B9_7F4A_7C15 }
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func float() -> Float {
        // Top 24 bits → [0, 1)
        Float(next() >> 40) * (1.0 / Float(1 << 24))
    }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + float() * (range.upperBound - range.lowerBound)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }
}

/// FNV-1a 64-bit (stable across Swift launches, unlike `String.hashValue`).
func stableHash64(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in s.utf8 {
        h ^= UInt64(byte)
        h = h &* 0x0000_0100_0000_01b3
    }
    return h
}
