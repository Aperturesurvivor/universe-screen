// Body — a live Codex agent visualized as a small spacecraft travelling
// between the Internet Star and the project planet that owns its working tree.
//
// AgentBody intentionally does not conform to CelestialBody yet: the baseline
// BodyKind enum has no `.agent` case. Its public surface already matches the
// protocol (stableId/name/actionURL/position/radius), so integration only needs
// `case agent` plus `extension AgentBody: CelestialBody { var kind: BodyKind { .agent } }`.
import Foundation
import simd

enum AgentVisualState: UInt32, CaseIterable, Codable, Sendable {
    case launching = 0
    case working   = 1
    case waiting   = 2
    case succeeded = 3
    case failed    = 4
    case returning = 5
}

/// Coarse, privacy-safe activity drives motion without exposing tool names,
/// prompts, commands, or content.
enum AgentActivityMode: UInt32, CaseIterable, Codable, Sendable {
    case starting      = 0
    case thinking      = 1
    case usingTool     = 2
    case communicating = 3
    case working       = 4
    case waiting       = 5
    case finished      = 6
    case interrupted   = 7
}

struct AgentBody: Identifiable, Sendable {
    static let codexBlue = SIMD3<Float>(0.16, 0.72, 1.00)

    let stableId: String
    var name: String
    var actionURL: URL?

    /// Endpoints in Universe world space. The renderer builds a deterministic
    /// curved flight path between them, so callers only need to track planets.
    var startPosition: SIMD3<Float>
    var targetPosition: SIMD3<Float>

    /// 0 = at start, 1 = docked at target.
    var progress: Float
    /// Fraction of the total path retained as a visible exhaust trail.
    var trailLength: Float
    /// Stable per-agent phase used to pick curve direction and desynchronise glow.
    var phase: Float
    /// Half-length of the low-poly ship in world units.
    var size: Float
    /// Master emissive multiplier. Normal useful range is 0...1.5.
    var intensity: Float
    var tint: SIMD3<Float>
    var state: AgentVisualState
    var activityMode: AgentActivityMode
    /// Stable hash of the most recent sanitized filesystem location. The raw
    /// path does not enter GPU buffers or labels.
    var locationFingerprint: UInt64
    /// Relative depth below the visible project world, capped by Universe.
    var locationDepth: UInt32
    /// Seconds since the latest coarse activity transition.
    var activityTime: Float
    /// Starts at one on a transition and decays, giving the new action emphasis.
    var activityPulse: Float

    var id: String { stableId }
    var radius: Float { size }

    /// CPU equivalent of the Metal flight path, useful for labels and hit tests.
    var position: SIMD3<Float> {
        let base = Self.pointOnPath(
            from: startPosition,
            to: targetPosition,
            progress: progress,
            phase: phase,
            size: size)
        let docked = Self.smoothStep(edge0: 0.90, edge1: 1.0, value: progress)
        return base + Self.activityOffset(
            mode: activityMode,
            time: activityTime,
            pulse: activityPulse,
            phase: phase,
            size: size) * docked
    }

    init(stableId: String,
         name: String,
         actionURL: URL? = nil,
         startPosition: SIMD3<Float>,
         targetPosition: SIMD3<Float>,
         progress: Float = 0,
         trailLength: Float = 0.34,
         phase: Float? = nil,
         size: Float = 13,
         intensity: Float = 1,
         tint: SIMD3<Float> = AgentBody.codexBlue,
         state: AgentVisualState = .launching,
         activityMode: AgentActivityMode = .starting,
         locationFingerprint: UInt64 = 0,
         locationDepth: UInt32 = 0,
         activityTime: Float = 0,
         activityPulse: Float = 1) {
        self.stableId = stableId
        self.name = name
        self.actionURL = actionURL
        self.startPosition = startPosition
        self.targetPosition = targetPosition
        self.progress = Self.clampFinite(progress, to: 0...1, fallback: 0)
        self.trailLength = Self.clampFinite(trailLength, to: 0.04...1, fallback: 0.34)
        if let phase, phase.isFinite {
            self.phase = phase
        } else {
            self.phase = Self.stablePhase(for: stableId)
        }
        self.size = Self.clampFinite(size, to: 7...28, fallback: 13)
        self.intensity = Self.clampFinite(intensity, to: 0...2, fallback: 1)
        self.tint = SIMD3(
            tint.x.isFinite ? max(0, tint.x) : Self.codexBlue.x,
            tint.y.isFinite ? max(0, tint.y) : Self.codexBlue.y,
            tint.z.isFinite ? max(0, tint.z) : Self.codexBlue.z)
        self.state = state
        self.activityMode = activityMode
        self.locationFingerprint = locationFingerprint
        self.locationDepth = locationDepth
        self.activityTime = activityTime.isFinite ? max(0, activityTime) : 0
        self.activityPulse = Self.clampFinite(activityPulse, to: 0...1, fallback: 1)
    }

    /// Retarget without teleporting: the currently rendered position becomes
    /// the beginning of the new journey.
    mutating func retarget(to newTarget: SIMD3<Float>, state newState: AgentVisualState = .launching) {
        startPosition = position
        targetPosition = newTarget
        progress = 0
        state = newState
    }

    mutating func advanceJourney(deltaTime: Float, duration: Float = 2.4) {
        guard deltaTime.isFinite, deltaTime > 0 else { return }
        let safeDuration = max(0.15, duration.isFinite ? duration : 2.4)
        progress = min(1, progress + deltaTime / safeDuration)
        activityTime += deltaTime
        activityPulse = max(0, activityPulse - deltaTime * 0.72)
        if progress >= 1, state == .launching {
            state = .working
            if activityMode == .starting {
                setActivityMode(.working)
            }
        }
    }

    mutating func setActivityMode(_ mode: AgentActivityMode) {
        guard activityMode != mode else { return }
        activityMode = mode
        activityTime = 0
        activityPulse = 1
    }

    var gpu: AgentGPU {
        AgentGPU(
            startPosition: SIMD4(startPosition, 1),
            targetPosition: SIMD4(targetPosition, 1),
            tint: SIMD4(tint, intensity),
            motion: SIMD4(progress, trailLength, phase, size),
            behavior: SIMD4(activityTime, activityPulse, 0, 0),
            state: SIMD4(state.rawValue, activityMode.rawValue, 0, 0))
    }

    static func pointOnPath(from start: SIMD3<Float>,
                            to target: SIMD3<Float>,
                            progress: Float,
                            phase: Float,
                            size: Float) -> SIMD3<Float> {
        let t = smootherStep(clampFinite(progress, to: 0...1, fallback: 0))
        let control = pathControl(from: start, to: target, phase: phase, size: size)
        let oneMinusT = 1 - t
        return oneMinusT * oneMinusT * start
             + 2 * oneMinusT * t * control
             + t * t * target
    }

    static func pathControl(from start: SIMD3<Float>,
                            to target: SIMD3<Float>,
                            phase: Float,
                            size: Float) -> SIMD3<Float> {
        let delta = target - start
        let planar = SIMD2<Float>(delta.x, delta.z)
        let distance = simd_length(planar)
        let perpendicular: SIMD2<Float>
        if distance > 0.001 {
            perpendicular = SIMD2(-planar.y, planar.x) / distance
        } else {
            perpendicular = SIMD2(1, 0)
        }
        let bendSign: Float = sin(phase * 1.618 + 0.73) >= 0 ? 1 : -1
        let bend = min(distance * 0.24, 180) * bendSign
        var control = (start + target) * 0.5
        control.x += perpendicular.x * bend
        control.z += perpendicular.y * bend
        control.y = max(start.y, target.y) + max(12, size * 1.65)
        return control
    }

    /// State-driven motion around the project dock. Tool use makes a fast
    /// figure-eight, communication opens into a wider relay loop, ordinary
    /// work patrols the project, and waiting settles into a quiet hover.
    static func activityOffset(
        mode: AgentActivityMode,
        time: Float,
        pulse: Float,
        phase: Float,
        size: Float
    ) -> SIMD3<Float> {
        let t = max(0, time)
        let emphasis = 1 + min(1, max(0, pulse)) * 0.34
        let radius = max(30, size * 2.35) * emphasis

        switch mode {
        case .starting:
            return .zero
        case .thinking:
            let angle = t * 0.72 + phase
            return SIMD3(cos(angle) * radius * 0.56,
                         sin(angle * 1.7) * size * 0.13,
                         sin(angle) * radius * 0.56)
        case .usingTool:
            let angle = t * 2.05 + phase
            return SIMD3(cos(angle) * radius,
                         (0.5 + 0.5 * sin(angle * 2.0)) * size * 0.24,
                         sin(angle * 2.0) * radius * 0.62)
        case .communicating:
            let angle = t * 1.38 + phase
            let breathingRadius = radius * (1.05 + 0.22 * sin(angle * 0.5))
            return SIMD3(cos(angle) * breathingRadius,
                         (0.5 + 0.5 * sin(angle * 3.0)) * size * 0.34,
                         sin(angle) * breathingRadius)
        case .working:
            let angle = t * 1.02 + phase
            return SIMD3(cos(angle) * radius * 0.78,
                         (0.5 + 0.5 * sin(angle * 2.0)) * size * 0.18,
                         sin(angle) * radius * 0.78)
        case .waiting:
            let angle = t * 0.46 + phase
            return SIMD3(cos(angle) * size * 0.18,
                         (0.5 + 0.5 * sin(angle * 2.2)) * size * 0.12,
                         sin(angle) * size * 0.18)
        case .finished:
            let decay = exp(-t * 0.46)
            let angle = t * 1.7 + phase
            return SIMD3(cos(angle) * radius * 0.46 * decay,
                         sin(angle * 2.0) * size * 0.18 * decay,
                         sin(angle) * radius * 0.46 * decay)
        case .interrupted:
            let angle = t * 3.4 + phase
            return SIMD3(sin(angle * 1.7) * size * 0.42,
                         sin(angle * 2.3) * size * 0.12,
                         cos(angle * 1.3) * size * 0.42)
        }
    }

    private static func stablePhase(for id: String) -> Float {
        let unit = Float(stableHash64(id) & 0x00FF_FFFF) / Float(0x0100_0000)
        return unit * 2 * .pi
    }

    private static func smootherStep(_ value: Float) -> Float {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private static func smoothStep(edge0: Float, edge1: Float, value: Float) -> Float {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private static func clampFinite(_ value: Float,
                                    to range: ClosedRange<Float>,
                                    fallback: Float) -> Float {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// 96-byte stride; matches AgentGPU in agent.metal.
struct AgentGPU {
    var startPosition:  SIMD4<Float>   // offset  0
    var targetPosition: SIMD4<Float>   // offset 16
    /// xyz = primary color, w = emissive intensity.
    var tint:           SIMD4<Float>   // offset 32
    /// x = progress, y = trailLength, z = phase, w = ship size.
    var motion:         SIMD4<Float>   // offset 48
    /// x = activity time, y = transition pulse; remaining lanes reserved.
    var behavior:       SIMD4<Float>   // offset 64
    /// x = AgentVisualState, y = AgentActivityMode.
    var state:          SIMD4<UInt32>  // offset 80 -> stride 96
}
