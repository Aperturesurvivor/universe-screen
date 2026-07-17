// Engine — the polymorphic interface every body in the universe satisfies.
// Concrete types (PlanetBody, AsteroidBody, eventually StarBody, BlackHoleBody, …)
// live in /Bodies. Each kind owns its own GPU layout and render pipeline.
import Foundation
import simd

enum BodyKind: String, Codable, CaseIterable {
    case planet
    case asteroid
    case agent
    case star          // stub for Phase 5 (default browser)
    case blackHole     // stub for Phase 6 (Trash)
    case warpGate      // stub for Phase 6 (Mail)
    case station       // stub for Phase 6 (Messages)
}

/// Cross-cutting view of any body — used for hit-testing, labels, and click actions.
/// Concrete bodies live in their own typed arrays inside `Universe` for efficient
/// per-kind GPU buffer uploads.
protocol CelestialBody {
    /// Stable, human-meaningful identifier (e.g. file URL string). Drives RNG seeding.
    var stableId:  String     { get }
    var kind:      BodyKind   { get }
    var name:      String     { get }
    var actionURL: URL?       { get }

    /// World position (y = 0 plane in the current top-down camera setup).
    var position:  SIMD3<Float> { get }
    /// World-space radius for hit-testing & label anchoring.
    var radius:    Float        { get }
}

extension AgentBody: CelestialBody {
    var kind: BodyKind { .agent }
}
