// Agent spacecraft — low-poly probe hull, twin analytic thrusters, and a
// tapered quadratic-Bezier trail. Designed for the existing top-down world
// coordinate system (+Y up, projects on the XZ plane).
#include <metal_stdlib>
using namespace metal;

struct AgentGPU {
    float4 startPosition;
    float4 targetPosition;
    float4 tint;       // xyz color, w intensity
    float4 motion;     // progress, trailLength, phase, size
    float4 behavior;   // activity time, transition pulse, reserved
    uint4  state;      // x = AgentVisualState, y = AgentActivityMode
};

struct AgentMeshVertex {
    float4 position;
    float4 normalAndMaterial;
};

struct CameraUniforms {
    float4x4 viewProjection;
    float4   cameraPos;
    float4   lightPos;
};

struct MotionUniforms {
    float    time;
    float    motionAmount;
    float    cursorPushStrength;
    uint     cursorEnabled;
    float4   cursorWorldPos;
};

constant uint kAgentLaunching = 0;
constant uint kAgentWorking   = 1;
constant uint kAgentWaiting   = 2;
constant uint kAgentSucceeded = 3;
constant uint kAgentFailed    = 4;
constant uint kAgentReturning = 5;
constant uint kActivityStarting      = 0;
constant uint kActivityThinking      = 1;
constant uint kActivityUsingTool     = 2;
constant uint kActivityCommunicating = 3;
constant uint kActivityWorking       = 4;
constant uint kActivityWaiting       = 5;
constant uint kActivityFinished      = 6;
constant uint kActivityInterrupted   = 7;
constant uint kTrailSegments  = 36;

static inline float smootherStep(float value) {
    float t = saturate(value);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

static inline float3 stateTint(float3 base, uint state) {
    if (state == kAgentLaunching) return mix(base, float3(0.82, 0.96, 1.00), 0.16);
    if (state == kAgentWorking)   return base;
    if (state == kAgentWaiting)   return mix(base, float3(1.00, 0.62, 0.16), 0.72);
    if (state == kAgentSucceeded) return mix(base, float3(0.22, 1.00, 0.54), 0.78);
    if (state == kAgentFailed)    return mix(base, float3(1.00, 0.16, 0.24), 0.86);
    if (state == kAgentReturning) return mix(base, float3(0.70, 0.42, 1.00), 0.62);
    return base;
}

static inline float3 pathControl(AgentGPU agent) {
    float3 start = agent.startPosition.xyz;
    float3 target = agent.targetPosition.xyz;
    float2 planar = target.xz - start.xz;
    float distance = length(planar);
    float2 perpendicular = distance > 0.001
        ? float2(-planar.y, planar.x) / distance
        : float2(1.0, 0.0);
    float bendSign = sin(agent.motion.z * 1.618 + 0.73) >= 0.0 ? 1.0 : -1.0;
    float bend = min(distance * 0.24, 180.0) * bendSign;
    float3 control = mix(start, target, 0.5);
    control.xz += perpendicular * bend;
    control.y = max(start.y, target.y) + max(12.0, agent.motion.w * 1.65);
    return control;
}

static inline float3 pathPointRaw(AgentGPU agent, float t) {
    float3 a = agent.startPosition.xyz;
    float3 b = pathControl(agent);
    float3 c = agent.targetPosition.xyz;
    float u = 1.0 - t;
    return u * u * a + 2.0 * u * t * b + t * t * c;
}

static inline float3 pathPoint(AgentGPU agent, float linearProgress) {
    return pathPointRaw(agent, smootherStep(linearProgress));
}

static inline float3 pathTangent(AgentGPU agent, float linearProgress) {
    float t = smootherStep(linearProgress);
    float3 a = agent.startPosition.xyz;
    float3 b = pathControl(agent);
    float3 c = agent.targetPosition.xyz;
    float3 tangent = 2.0 * (1.0 - t) * (b - a) + 2.0 * t * (c - b);
    tangent.y = 0.0;
    if (length_squared(tangent) < 0.0001) tangent = float3(0.0, 0.0, 1.0);
    return normalize(tangent);
}

static inline float3 activityOffset(AgentGPU agent, float time) {
    uint mode = agent.state.y;
    float size = agent.motion.w;
    float pulse = saturate(agent.behavior.y);
    float emphasis = 1.0 + pulse * 0.34;
    float radius = max(30.0, size * 2.35) * emphasis;
    float phase = agent.motion.z;
    float t = max(0.0, time);

    if (mode == kActivityStarting) return float3(0.0);
    if (mode == kActivityThinking) {
        float angle = t * 0.72 + phase;
        return float3(cos(angle) * radius * 0.56,
                      sin(angle * 1.7) * size * 0.13,
                      sin(angle) * radius * 0.56);
    }
    if (mode == kActivityUsingTool) {
        float angle = t * 2.05 + phase;
        return float3(cos(angle) * radius,
                      (0.5 + 0.5 * sin(angle * 2.0)) * size * 0.24,
                      sin(angle * 2.0) * radius * 0.62);
    }
    if (mode == kActivityCommunicating) {
        float angle = t * 1.38 + phase;
        float breathingRadius = radius * (1.05 + 0.22 * sin(angle * 0.5));
        return float3(cos(angle) * breathingRadius,
                      (0.5 + 0.5 * sin(angle * 3.0)) * size * 0.34,
                      sin(angle) * breathingRadius);
    }
    if (mode == kActivityWorking) {
        float angle = t * 1.02 + phase;
        return float3(cos(angle) * radius * 0.78,
                      (0.5 + 0.5 * sin(angle * 2.0)) * size * 0.18,
                      sin(angle) * radius * 0.78);
    }
    if (mode == kActivityWaiting) {
        float angle = t * 0.46 + phase;
        return float3(cos(angle) * size * 0.18,
                      (0.5 + 0.5 * sin(angle * 2.2)) * size * 0.12,
                      sin(angle) * size * 0.18);
    }
    if (mode == kActivityFinished) {
        float decay = exp(-t * 0.46);
        float angle = t * 1.7 + phase;
        return float3(cos(angle) * radius * 0.46 * decay,
                      sin(angle * 2.0) * size * 0.18 * decay,
                      sin(angle) * radius * 0.46 * decay);
    }

    if (mode == kActivityInterrupted) {
        float angle = t * 3.4 + phase;
        return float3(sin(angle * 1.7) * size * 0.42,
                      sin(angle * 2.3) * size * 0.12,
                      cos(angle * 1.3) * size * 0.42);
    }
    return float3(0.0);
}

static inline float3 activityTangent(AgentGPU agent, float time) {
    float3 before = activityOffset(agent, max(0.0, time - 0.018));
    float3 after = activityOffset(agent, time + 0.018);
    float3 tangent = after - before;
    tangent.y = 0.0;
    if (length_squared(tangent) < 0.0001) return float3(0.0, 0.0, 1.0);
    return normalize(tangent);
}

static inline void shipFrame(AgentGPU agent,
                             constant MotionUniforms& motion,
                             thread float3& center,
                             thread float3& right,
                             thread float3& up,
                             thread float3& forward) {
    float progress = saturate(agent.motion.x);
    center = pathPoint(agent, progress);
    forward = pathTangent(agent, progress);
    float docked = smoothstep(0.90, 1.0, progress);
    center += activityOffset(agent, agent.behavior.x) * docked;
    uint activityMode = agent.state.y;
    if (docked > 0.95
        && activityMode != kActivityStarting
        && activityMode != kActivityWaiting
        && activityMode != kActivityFinished) {
        forward = activityTangent(agent, agent.behavior.x);
    }
    up = float3(0.0, 1.0, 0.0);
    right = normalize(cross(up, forward));

    uint state = agent.state.x;
    float hoverStrength = (state == kAgentWaiting || state == kAgentSucceeded) ? 1.0 : 0.35;
    float hover = sin(motion.time * 2.1 + agent.motion.z * 5.3) * agent.motion.w * 0.055;
    center += right * hover * hoverStrength;
    center.y += (0.5 + 0.5 * sin(motion.time * 2.7 + agent.motion.z))
              * agent.motion.w * 0.035;
}

// MARK: - Faceted spacecraft hull

struct ShipOut {
    float4 clipPos [[position]];
    float3 worldPos;
    float3 normal;
    float3 tint;
    float  intensity;
    float  material;
    uint   state [[flat]];
};

vertex ShipOut agentShipVertex(
    uint                         vid       [[vertex_id]],
    uint                         iid       [[instance_id]],
    constant AgentMeshVertex*    vertices  [[buffer(0)]],
    constant AgentGPU*           agents    [[buffer(1)]],
    constant CameraUniforms&     camera    [[buffer(2)]],
    constant MotionUniforms&     motion    [[buffer(3)]]) {
    AgentGPU agent = agents[iid];
    AgentMeshVertex meshVertex = vertices[vid];

    float3 center, right, up, forward;
    shipFrame(agent, motion, center, right, up, forward);
    float size = agent.motion.w;
    float3 local = meshVertex.position.xyz;
    float3 world = center
                 + right   * (local.x * size)
                 + up      * (local.y * size)
                 + forward * (local.z * size);
    float3 localNormal = meshVertex.normalAndMaterial.xyz;
    float3 worldNormal = normalize(right * localNormal.x
                                 + up * localNormal.y
                                 + forward * localNormal.z);

    ShipOut out;
    out.clipPos = camera.viewProjection * float4(world, 1.0);
    out.worldPos = world;
    out.normal = worldNormal;
    out.tint = stateTint(agent.tint.xyz, agent.state.x);
    out.intensity = agent.tint.w;
    out.material = meshVertex.normalAndMaterial.w;
    out.state = agent.state.x;
    return out;
}

fragment float4 agentShipFragment(ShipOut in [[stage_in]],
                                  constant CameraUniforms& camera [[buffer(2)]]) {
    float3 n = normalize(in.normal);
    float3 lightDirection = normalize(camera.lightPos.xyz - in.worldPos);
    float3 viewDirection = normalize(camera.cameraPos.xyz - in.worldPos);
    // The deliberately tiny faceted mesh is rendered two-sided. Face the flat
    // normal toward the camera so mirrored wing topology shades symmetrically.
    if (dot(n, viewDirection) < 0.0) n = -n;
    float3 halfDirection = normalize(lightDirection + viewDirection);
    float diffuse = 0.18 + max(dot(n, lightDirection), 0.0) * 0.82;
    float specular = pow(max(dot(n, halfDirection), 0.0), 42.0);
    float rim = pow(1.0 - max(dot(n, viewDirection), 0.0), 2.4);

    float3 graphite = float3(0.035, 0.055, 0.085);
    float3 color;
    float emissive = 0.0;
    if (in.material < 0.5) {
        color = mix(graphite, in.tint * 0.34, 0.34) * diffuse;
        color += specular * float3(0.72, 0.88, 1.0) * 0.34;
    } else if (in.material < 1.5) {
        color = mix(in.tint * 0.42, in.tint, diffuse);
        emissive = 0.34 * in.intensity;
    } else {
        float fresnel = pow(1.0 - max(dot(n, viewDirection), 0.0), 3.0);
        color = mix(float3(0.22, 0.48, 0.68), float3(0.78, 0.96, 1.0), fresnel);
        color *= 0.70 + diffuse * 0.45;
        emissive = 0.18 * in.intensity;
    }

    if (in.state == kAgentFailed) {
        float alarm = 0.55 + 0.45 * sin(in.worldPos.x * 0.11 + in.worldPos.z * 0.07);
        emissive *= alarm;
    }
    color += in.tint * (emissive + rim * 0.20 * in.intensity);
    color = color / (color + 0.62);
    return float4(color, 1.0);
}

// MARK: - Curved exhaust ribbon

struct TrailOut {
    float4 clipPos [[position]];
    float2 uv;
    float3 tint;
    float  intensity;
    float  phase;
    uint   state [[flat]];
};

vertex TrailOut agentTrailVertex(
    uint                         vid     [[vertex_id]],
    uint                         iid     [[instance_id]],
    constant AgentGPU*           agents  [[buffer(1)]],
    constant CameraUniforms&     camera  [[buffer(2)]],
    constant MotionUniforms&     motion  [[buffer(3)]]) {
    AgentGPU agent = agents[iid];
    uint segment = vid / 2;
    float side = (vid & 1u) == 0u ? -1.0 : 1.0;
    float u = float(segment) / float(kTrailSegments);
    float head = saturate(agent.motion.x);
    float tail = max(0.0, head - max(0.04, agent.motion.y));
    float pathT = mix(tail, head, u);
    uint activityMode = agent.state.y;
    bool activityTrail = head > 0.995
        && activityMode != kActivityStarting
        && activityMode != kActivityWaiting
        && activityMode != kActivityFinished;
    float3 center;
    float3 forward;
    if (activityTrail) {
        float trailSeconds = mix(0.32, 0.94, saturate(agent.motion.y));
        float sampleTime = max(0.0, agent.behavior.x - (1.0 - u) * trailSeconds);
        center = agent.targetPosition.xyz + activityOffset(agent, sampleTime);
        forward = activityTangent(agent, sampleTime);
    } else {
        center = pathPoint(agent, pathT);
        forward = pathTangent(agent, pathT);
    }
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), forward));

    float width = agent.motion.w * mix(0.035, 0.26, pow(u, 1.35));
    float flutter = sin(motion.time * 5.2 - u * 18.0 + agent.motion.z * 7.0)
                  * agent.motion.w * 0.018 * (1.0 - u);
    center += right * flutter;
    center.y += agent.motion.w * 0.02;
    float3 world = center + right * (side * width);

    TrailOut out;
    out.clipPos = camera.viewProjection * float4(world, 1.0);
    out.uv = float2(u, side);
    out.tint = stateTint(agent.tint.xyz, agent.state.x);
    out.intensity = (!activityTrail && head > 0.995) ? 0.0 : agent.tint.w;
    out.phase = agent.motion.z;
    out.state = agent.state.x;
    return out;
}

fragment float4 agentTrailFragment(TrailOut in [[stage_in]],
                                   constant MotionUniforms& motion [[buffer(3)]]) {
    float lateral = abs(in.uv.y);
    float core = exp(-lateral * lateral * 5.5);
    float edge = smoothstep(1.0, 0.08, lateral);
    float tailFade = smoothstep(0.0, 0.18, in.uv.x);
    float headFade = 1.0 - smoothstep(0.88, 1.02, in.uv.x);
    float packet = 0.72 + 0.28 * sin(in.uv.x * 34.0 - motion.time * 9.0 + in.phase * 4.0);
    packet = mix(0.78, 1.12, packet);
    float stateScale = in.state == kAgentSucceeded ? 0.42
                     : in.state == kAgentWaiting   ? 0.58
                     : in.state == kAgentFailed    ? 0.76
                     : 1.0;
    float alpha = core * edge * tailFade * headFade * packet * stateScale * in.intensity;
    float3 hot = mix(float3(0.82, 0.96, 1.0), in.tint, 0.62);
    float3 color = mix(in.tint * 0.38, hot, core) * alpha * 0.78;
    return float4(color, alpha);
}

// MARK: - Twin engine flames

struct EngineOut {
    float4 clipPos [[position]];
    float2 uv;
    float3 tint;
    float  intensity;
    float  phase;
    uint   state [[flat]];
};

vertex EngineOut agentEngineVertex(
    uint                         vid     [[vertex_id]],
    uint                         iid     [[instance_id]],
    constant AgentGPU*           agents  [[buffer(1)]],
    constant CameraUniforms&     camera  [[buffer(2)]],
    constant MotionUniforms&     motion  [[buffer(3)]]) {
    uint agentIndex = iid / 2;
    uint engineIndex = iid & 1u;
    AgentGPU agent = agents[agentIndex];
    const float2 corners[4] = {
        float2(-1.0, 0.0), float2(1.0, 0.0),
        float2(-1.0, 1.0), float2(1.0, 1.0)
    };

    float3 center, right, up, forward;
    shipFrame(agent, motion, center, right, up, forward);
    float size = agent.motion.w;
    float podSide = engineIndex == 0u ? -1.0 : 1.0;
    float2 corner = corners[vid];
    float3 base = center - forward * (size * 0.78)
                + right * (podSide * size * 0.29)
                + up * (size * 0.015);
    float flicker = 0.90 + 0.10 * sin(motion.time * 17.0 + agent.motion.z * 9.0 + float(engineIndex));
    float3 world = base
                 + right * (corner.x * size * 0.20)
                 - forward * (corner.y * size * 1.18 * flicker);

    EngineOut out;
    out.clipPos = camera.viewProjection * float4(world, 1.0);
    out.uv = corner;
    out.tint = stateTint(agent.tint.xyz, agent.state.x);
    out.intensity = agent.tint.w;
    out.phase = agent.motion.z + float(engineIndex) * 1.7;
    out.state = agent.state.x;
    return out;
}

fragment float4 agentEngineFragment(EngineOut in [[stage_in]],
                                    constant MotionUniforms& motion [[buffer(3)]]) {
    float x = in.uv.x;
    float y = in.uv.y;
    float cone = exp(-x * x * mix(11.0, 3.5, y));
    float lengthFade = pow(saturate(1.0 - y), 1.15);
    float flicker = 0.82 + 0.18 * sin(motion.time * 21.0 - y * 13.0 + in.phase * 5.0);
    float stateScale = in.state == kAgentSucceeded ? 0.34
                     : in.state == kAgentWaiting   ? 0.48
                     : 1.0;
    float alpha = cone * lengthFade * flicker * stateScale * in.intensity;
    float3 whiteCore = float3(0.90, 0.98, 1.0);
    float3 color = mix(in.tint, whiteCore, cone * (1.0 - y)) * alpha * 1.35;
    return float4(color, alpha);
}
