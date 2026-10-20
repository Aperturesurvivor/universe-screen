// Engine — owns every CelestialBody in the world and exposes typed arrays per kind
// so each kind's renderer can upload its own contiguous GPU buffer.
// Stays single-actor (main) for now; concurrency boundaries can be added later.
import AppKit
import simd

@MainActor
final class Universe {

    // Per-kind, typed for cheap GPU buffer uploads.
    private(set) var planets:   [PlanetBody]    = []
    private(set) var asteroids: [AsteroidBody]  = []
    private(set) var star:      StarBody?
    private(set) var blackHole: BlackHoleBody?
    // Stubs for future kinds — wired up in later phases:
    // private(set) var warpGate:  WarpGateBody?
    // private(set) var station:   StationBody?

    /// Last-known screen (in points). Used by per-body factories that need to map
    /// Finder icon coordinates onto the world.
    private(set) var screenSize: CGSize = .zero
    private(set) var seed: Seed
    private(set) var usingFinderPositions = false
    /// One entry per occupied shell, innermost first. Used by OrbitRingRenderer
    /// and by UniverseRenderer to compute the zoom target.
    private(set) var shellRadii: [Float] = []

    init(seed: Seed) {
        self.seed = seed
    }

    func setSeed(_ newSeed: Seed) {
        self.seed = newSeed
        newSeed.save()
        // Bodies derive visual properties from the seed, so the caller should
        // re-run a refresh after this to actually see the change.
    }

    // MARK: - Mutations

    /// Full rebuild from desktop data. Call after a scan.
    func update(folders: [FolderInfo], files: [FileInfo], screenSize: CGSize) {
        self.screenSize = screenSize
        usingFinderPositions =
            folders.contains { $0.iconPosition != nil }
            || files.contains { $0.iconPosition != nil }

        // Preserve per-planet state so animation continues smoothly across rebuilds.
        let prevAngles = Dictionary(uniqueKeysWithValues: planets.map { ($0.stableId, $0.orbitAngle) })
        let prevRadii  = Dictionary(uniqueKeysWithValues: planets.map { ($0.stableId, $0.orbitRadius) })

        planets   = folders.map { PlanetBody.make(from: $0, screenSize: screenSize, seed: seed) }
        asteroids = files.map   { AsteroidBody.make(from: $0, screenSize: screenSize, seed: seed) }
        blackHole = BlackHoleBody.make(screenSize: screenSize, seed: seed)

        let starCenter = SIMD3(Float(screenSize.width) * 0.5, 0, Float(screenSize.height) * 0.5)
        let minDim     = Float(min(screenSize.width, screenSize.height))

        // Ground-state (lowest-energy) assignment: sort by stable hash so each folder
        // always owns the same position in the ordering, then pack inner → outer.
        // Each planet's orbitRadius lerps toward its ground-state target each frame.
        let sorted = planets.indices.sorted {
            stableHash64(planets[$0].stableId) < stableHash64(planets[$1].stableId)
        }

        var assignments: [(pi: Int, shell: Int)] = []
        var curShell = 0, curSlot = 0
        for pi in sorted {
            let cap = PlanetBody.shellCapacity(shellIndex: curShell, minDim: minDim)
            if curSlot >= cap { curShell += 1; curSlot = 0 }
            assignments.append((pi: pi, shell: curShell))
            planets[pi].shellIndex = curShell
            curSlot += 1
        }

        // Publish ground-state ring radii for the orbit ring renderer.
        let numShells = assignments.isEmpty ? 0 : assignments.last!.shell + 1
        shellRadii = (0..<numShells).map { PlanetBody.shellRadius(shellIndex: $0, minDim: minDim) }

        // Spawn radius for brand-new planets: one shell beyond the outermost ground-state
        // shell, so they appear at the outer edge and then spiral inward.
        let spawnRadius = PlanetBody.shellRadius(shellIndex: numShells, minDim: minDim)

        let k: Float = 100
        for a in assignments {
            let targetR = PlanetBody.shellRadius(shellIndex: a.shell, minDim: minDim)
            planets[a.pi].targetOrbitRadius = targetR
            planets[a.pi].orbitSpeed = k / pow(targetR, 1.5)

            if let prevR = prevRadii[planets[a.pi].stableId] {
                // Existing planet: continue animating from its current radius.
                planets[a.pi].orbitRadius = prevR
            } else {
                // New planet: spawn at the outer edge; advanceOrbit lerps it inward.
                planets[a.pi].orbitRadius = spawnRadius
            }
            planets[a.pi].orbitAngle = 0
            planets[a.pi].position   = SIMD3(starCenter.x + planets[a.pi].orbitRadius, 0, starCenter.z)
        }

        // Restore orbital angles for planets that existed before the rebuild.
        for a in assignments {
            guard let angle = prevAngles[planets[a.pi].stableId] else { continue }
            planets[a.pi].orbitAngle = angle
            planets[a.pi].position   = SIMD3(
                starCenter.x + cos(angle) * planets[a.pi].orbitRadius,
                0,
                starCenter.z + sin(angle) * planets[a.pi].orbitRadius)
        }

        // Place brand-new planets at the largest angular gap on their target shell.
        // They spawn at spawnRadius but use the target shell's gap so they fall
        // straight inward along their final orbital lane.
        var shellAngles: [Int: [Float]] = [:]
        for a in assignments {
            if prevAngles[planets[a.pi].stableId] != nil {
                shellAngles[a.shell, default: []].append(planets[a.pi].orbitAngle)
            }
        }
        for a in assignments {
            guard prevAngles[planets[a.pi].stableId] == nil else { continue }
            if var angles = shellAngles[a.shell], !angles.isEmpty {
                let angle = Self.largestGapMidpoint(angles)
                planets[a.pi].orbitAngle = angle
                planets[a.pi].position   = SIMD3(
                    starCenter.x + cos(angle) * planets[a.pi].orbitRadius,
                    0,
                    starCenter.z + sin(angle) * planets[a.pi].orbitRadius)
                angles.append(angle)
                shellAngles[a.shell] = angles
            } else {
                let angle = Float(a.shell) * 0.4
                planets[a.pi].orbitAngle = angle
                planets[a.pi].position   = SIMD3(
                    starCenter.x + cos(angle) * planets[a.pi].orbitRadius,
                    0,
                    starCenter.z + sin(angle) * planets[a.pi].orbitRadius)
                shellAngles[a.shell] = [angle]
            }
        }
    }

    /// Midpoint of the largest angular gap in a circular list of angles.
    private static func largestGapMidpoint(_ angles: [Float]) -> Float {
        let twoPi: Float = 2 * .pi
        guard angles.count > 1 else {
            return ((angles[0] + .pi).truncatingRemainder(dividingBy: twoPi) + twoPi)
                .truncatingRemainder(dividingBy: twoPi)
        }
        let s = angles.sorted()
        var maxGap: Float = 0
        var bestMid: Float = s[0] + .pi   // fallback: opposite the first
        for i in 0..<s.count {
            let a   = s[i]
            let b   = i + 1 < s.count ? s[i + 1] : s[0] + twoPi
            let gap = b - a
            if gap > maxGap {
                maxGap  = gap
                bestMid = a + gap * 0.5
            }
        }
        return (bestMid.truncatingRemainder(dividingBy: twoPi) + twoPi)
            .truncatingRemainder(dividingBy: twoPi)
    }

    /// Advance all planet orbits by `deltaTime` seconds. Call once per frame.
    func tick(deltaTime: Float) {
        let starCenter: SIMD3<Float>
        if let s = star {
            starCenter = s.position
        } else {
            starCenter = SIMD3(Float(screenSize.width) * 0.5, 0, Float(screenSize.height) * 0.5)
        }
        let dt = min(deltaTime, 0.1)   // cap to avoid jumps after background sleep
        for i in planets.indices { planets[i].advanceOrbit(deltaTime: dt, starCenter: starCenter) }
    }

    /// Update the central Internet Star — call when the default browser or
    /// network state changes, or when the screen size does.
    func updateStar(browser: BrowserInfo,
                    isOnline:     Bool,
                    temperature:  Float,
                    intensity:    Float,
                    stability:    Float,
                    coronaScale:  Float,
                    flareDensity: Float,
                    screenSize:   CGSize) {
        self.screenSize = screenSize
        star = StarBody.make(browser: browser,
                             isOnline:     isOnline,
                             temperature:  temperature,
                             intensity:    intensity,
                             stability:    stability,
                             coronaScale:  coronaScale,
                             flareDensity: flareDensity,
                             screenSize:   screenSize,
                             seed:         seed)
    }

    /// Position-only refresh — fast path for icon drag polling.
    /// Returns true if any body actually moved.
    /// Planets are orbit-driven (tick() owns their position), so only asteroids are updated here.
    @discardableResult
    func updatePositions(_ positions: [String: CGPoint]) -> Bool {
        guard !positions.isEmpty,
              screenSize.width > 1, screenSize.height > 1 else { return false }

        var changed = false

        for i in asteroids.indices {
            guard let icon = positions[asteroids[i].name] else { continue }
            let new = SIMD3<Float>(Float(icon.x), 0, Float(icon.y))
            if simd_distance_squared(asteroids[i].position, new) > 1.0 {
                asteroids[i].position = new
                changed = true
            }
        }
        return changed
    }

    // MARK: - Hit-testing

    /// Cross-kind hit test on the y=0 plane. Returns the topmost body whose disk
    /// contains the cursor — planets win over asteroids when overlapping.
    func body(atWorld point: SIMD3<Float>) -> (any CelestialBody)? {
        let p2 = SIMD2(point.x, point.z)
        // Planets first so they win when overlapping the star at center.
        if let hit = nearestHit(in: planets, point: p2) { return hit }
        if let hit = nearestHit(in: asteroids, point: p2) { return hit }
        if let s = star {
            let c = SIMD2(s.position.x, s.position.z)
            if simd_distance(c, p2) <= s.radius { return s }
        }
        if let bh = blackHole {
            let c = SIMD2(bh.position.x, bh.position.z)
            if simd_distance(c, p2) <= bh.radius { return bh }
        }
        return nil
    }

    private func nearestHit<B: CelestialBody>(in bodies: [B],
                                              point: SIMD2<Float>) -> B? {
        var best: (B, Float)?
        for b in bodies {
            let c = SIMD2(b.position.x, b.position.z)
            let d = simd_distance(c, point)
            if d <= b.radius {
                if best == nil || d < best!.1 { best = (b, d) }
            }
        }
        return best?.0
    }
}
