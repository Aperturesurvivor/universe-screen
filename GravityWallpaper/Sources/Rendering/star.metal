// Internet Star — true 3D sphere shaded with the browser's 4-stop palette.
// All real-time variables come from the StarGPU struct (NWPath-driven).
//
//   pass 1: starSurface  — 3D sphere, ridged-noise turbulence, 3-stop radial
//                          color (limb → mid → core), accent highlights in
//                          cloud peaks, sunspots, vertex displacement.
//   pass 2: starHalo     — billboarded corona (size = star.coronaScale),
//                          wispy plasma + occasional looping prominences
//                          (frequency = star.flareDensity).
//   pass 3: starLensFlare— minimal cinematic atmospheric bleed.
#include <metal_stdlib>
#include "noise.h"
using namespace metal;

struct StarGPU {
    float4 position;
    float4 coreColor;
    float4 midColor;
    float4 limbColor;
    float4 accentColor;
    float  radius;
    float  pulseRate;
    float  intensity;
    float  phase;
    float  temperature;
    float  stability;
    float  coronaScale;
    float  flareDensity;
    float  seed;
    float  _pad0, _pad1, _pad2;
};

struct MeshVertex {
    float3 position;
    float  _pad;
};

struct CameraUniforms {
    float4x4 viewProjection;
    float4   cameraPos;
    float4   lightPos;
};

struct LabelUniforms {
    float4 cameraRight;
    float4 cameraUp;
    float  worldHeight;
    float  layerAspect;
    float  _pad0, _pad1;
};

struct MotionUniforms {
    float    time;
    float    motionAmount;
    float    cursorPushStrength;
    uint     cursorEnabled;
    float4   cursorWorldPos;
};

struct LensFlareUniforms {
    float2 screenSize;
    float  _pad0, _pad1;
};

// Subtle warm/cool tint multiplier (applied only as a final pass)
static inline float3 temperatureTint(float temp) {
    const float3 cool = float3(0.95, 1.00, 1.08);
    const float3 mid  = float3(1.00, 1.00, 1.00);
    const float3 warm = float3(1.08, 0.92, 0.78);
    if (temp >= 0.5) return mix(mid, cool, smoothstep(0.5, 1.0, temp));
    else             return mix(warm, mid, smoothstep(0.0, 0.5, temp));
}

static inline float3 rotateX(float3 p, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float3(p.x, p.y * c - p.z * s, p.y * s + p.z * c);
}

static inline float3 rotateZ(float3 p, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float3(p.x * c - p.y * s, p.x * s + p.y * c, p.z);
}

static inline float3 orientedStarUnit(float3 unit, float seed) {
    // A fixed tilt keeps the UV-sphere pole from sitting exactly at screen
    // center, which avoids visible concentric pinching in the hottest region.
    float tiltX = 0.72 + fract(seed * 0.013) * 0.30;
    float tiltZ = -0.58 + fract(seed * 0.021) * 0.24;
    return normalize(rotateZ(rotateX(unit, tiltX), tiltZ));
}

static inline float starDisplacement(float3 unit, float time, constant StarGPU& star) {
    float chaos = 1.0 - star.stability;
    float baseRate = 0.06 + chaos * 0.16;

    float3 cellP = unit * 3.2
                 + float3(time * baseRate * 0.9, time * baseRate * 0.7, time * baseRate * 1.1)
                 + star.seed * 0.19;
    float cells = ridgedFbm5(cellP);

    float3 granP = unit * 13.5
                 + float3(time * baseRate * 2.8, time * baseRate * 2.2, time * baseRate * 3.1)
                 + star.seed * 0.53;
    float gran = ridgedFbm5(granP);

    float3 shearP = unit * 8.4
                  + float3(time * baseRate * 1.6, -time * baseRate * 1.9, time * baseRate * 1.3)
                  + star.seed * 0.37;
    float shear = fbm5(shearP) * 0.5 + 0.5;

    float disp = cells * 0.62 + gran * 0.24 + shear * 0.14;
    float amp  = 0.020 + chaos * 0.040;
    return (disp - 0.5) * amp;
}

static inline float3 solarCoreColor() { return float3(1.00, 0.96, 0.88); }
static inline float3 solarMidColor()  { return float3(1.00, 0.78, 0.46); }
static inline float3 solarLimbColor() { return float3(0.98, 0.38, 0.16); }

// ─────────────────────────────────────────────────────────────
// PASS 1 — turbulent 3D surface
// ─────────────────────────────────────────────────────────────

struct StarSurfaceOut {
    float4 clipPos    [[ position ]];
    float3 worldPos;
    float3 unit;
    float3 normal;
    float  displacement;
};

vertex StarSurfaceOut starSurfaceVertex(
    uint                       vid    [[ vertex_id ]],
    constant MeshVertex*       verts  [[ buffer(0) ]],
    constant StarGPU&          star   [[ buffer(1) ]],
    constant CameraUniforms&   cam    [[ buffer(2) ]],
    constant MotionUniforms&   motion [[ buffer(3) ]]
) {
    float3 unit = orientedStarUnit(verts[vid].position, star.seed);
    float  disp = starDisplacement(unit, motion.time, star);
    float3 worldPos = star.position.xyz + unit * star.radius * (1.0 + disp);

    StarSurfaceOut out;
    out.clipPos  = cam.viewProjection * float4(worldPos, 1.0);
    out.worldPos = worldPos;
    out.unit     = unit;
    out.normal   = unit;
    out.displacement = disp;
    return out;
}

fragment float4 starSurfaceFragment(
    StarSurfaceOut             in     [[ stage_in ]],
    constant StarGPU&          star   [[ buffer(1) ]],
    constant CameraUniforms&   cam    [[ buffer(2) ]],
    constant MotionUniforms&   motion [[ buffer(3) ]]
) {
    float3 unit = in.unit;
    float  t    = motion.time;
    float  s    = star.seed;
    float3 N    = normalize(in.normal);

    float chaos      = 1.0 - star.stability;
    float scrollRate = 0.05 + chaos * 0.22;

    // ---- Convection cells + granulation + broad flow ----
    float3 flowVec = float3(
        fbm5(unit * 1.7 + float3(0.0, t * scrollRate * 0.30, s * 0.11)),
        fbm5(unit.zxy * 1.9 + float3(s * 0.07, 0.0, t * scrollRate * 0.26)),
        fbm5(unit.yzx * 1.8 + float3(t * scrollRate * 0.22, s * 0.13, 0.0))
    ) * 0.18;

    float3 pCells  = unit * 2.1 + flowVec
                   + float3(t * scrollRate * 0.55, t * scrollRate * 0.42, t * scrollRate * 0.74) + s * 1.7;
    float cells = ridgedFbm5(pCells);

    float3 pLanes = unit * 4.2 + flowVec * 1.5
                  + float3(t * scrollRate * 1.15, -t * scrollRate * 1.30, t * scrollRate * 1.05) + s * 3.9;
    float lanes = fbm5(pLanes) * 0.5 + 0.5;

    float3 pGran = unit * 14.0 + flowVec * 2.0
                 + float3(t * scrollRate * 2.3, t * scrollRate * 2.7, t * scrollRate * 2.0) + s * 5.7;
    float gran = ridgedFbm5(pGran);

    float3 pFlow = unit * 6.6
                 + float3(t * scrollRate * 0.9, t * scrollRate * 1.1, -t * scrollRate * 0.8) + s * 8.1;
    float flow = fbm5(pFlow) * 0.5 + 0.5;

    float cellsInv = 1.0 - cells;
    float convection = saturate(cellsInv * 0.58 + gran * 0.27 + flow * 0.15);
    float darkLanes = smoothstep(0.42, 0.72, lanes) * (1.0 - smoothstep(0.48, 0.88, cellsInv));

    // ---- Sunspots (sparse, slow). Slightly more when network is unstable. ----
    float3 pSpot = unit * 2.6 + flowVec
                 + float3(t * 0.018, t * 0.022, t * 0.020) + s * 11.3;
    float sunspot = smoothstep(0.66, 0.78, fbm5(pSpot)) * (0.45 + chaos * 0.20);

    // ---- View-relative radial position (1 = center, 0 = limb) ----
    float3 V = normalize(cam.cameraPos.xyz - in.worldPos);
    float NdotV = max(0.0, dot(N, V));
    float rim = pow(1.0 - NdotV, 3.6);
    float centerGlow = smoothstep(0.18, 0.95, NdotV);

    float3 baseCore = solarCoreColor();
    float3 baseMid  = solarMidColor();
    float3 baseLimb = solarLimbColor();

    // Browser colors are an accent system layered over a warm solar body,
    // so the star always reads as a sun first and a browser theme second.
    float3 browserWarm = mix(star.midColor.xyz, star.limbColor.xyz, 0.35);
    baseMid  = mix(baseMid,  browserWarm,          0.20);
    baseLimb = mix(baseLimb, browserWarm,          0.24);
    baseCore = mix(baseCore, star.coreColor.xyz,   0.10);

    float3 baseCol = mix(baseLimb, baseMid, smoothstep(0.00, 0.55, NdotV));
    baseCol = mix(baseCol, baseCore, smoothstep(0.48, 0.96, NdotV));

    float brightness = 0.88 + convection * 0.34;
    brightness *= mix(0.94, 1.18, centerGlow);
    brightness *= 1.0 - darkLanes * 0.18;
    brightness *= 1.0 - sunspot * 0.24;

    float3 color = baseCol * brightness;

    // Hot seams stay near-white/yellow like the reference rather than going magenta.
    float seamMask = smoothstep(0.56, 0.92, gran) * smoothstep(0.38, 0.86, convection);
    float3 seamColor = mix(baseCore * 1.10, float3(1.0, 0.99, 0.96), 0.55);
    color = mix(color, seamColor, seamMask * 0.36);

    // Dark inter-cell lanes add the mottled solar texture.
    color = mix(color, baseLimb * 0.82, darkLanes * 0.18);

    // Browser accents are subtle and mostly live in the hottest active zones.
    float accentMask = smoothstep(0.72, 0.96, seamMask + convection * 0.32) * (0.35 + chaos * 0.20);
    float3 accentTint = mix(baseCore, star.accentColor.xyz, 0.28);
    color = mix(color, accentTint, accentMask * 0.12);

    // Gentle self-shadowing / volume cue so the sphere has depth instead of a flat disc.
    color *= mix(0.94, 1.05, NdotV);
    color += baseLimb * rim * 0.05;

    // Inner radiance keeps the star feeling self-luminous instead of muddy.
    float coreBloom = smoothstep(0.46, 0.98, NdotV);
    color += mix(baseCore * 0.10, float3(1.0, 0.995, 0.98) * 0.24, coreBloom) * coreBloom;

    // Subtle blackbody tint over the browser palette
    color *= temperatureTint(star.temperature);

    // Pulse + intensity. Capped so the surface never blows out.
    float pulse = 0.96 + 0.04 * sin(t * star.pulseRate + star.phase);
    color *= min(star.intensity * pulse, 1.03);

    // Keep the surface visible and textured even at high intensity.
    float lum = max(color.r, max(color.g, color.b));
    if (lum > 1.28) {
        color *= 1.28 / lum;
    }

    return float4(color, 1.0);
}

// ─────────────────────────────────────────────────────────────
// PASS 2 — corona + occasional prominences
// Halo size scales with star.coronaScale; flares scale with flareDensity.
// ─────────────────────────────────────────────────────────────

struct StarHaloOut {
    float4 clipPos [[ position ]];
    float2 uv;
    float  coronaMult;     // pre-computed billboard / sphere ratio
};

vertex StarHaloOut starHaloVertex(
    uint                     vid   [[ vertex_id ]],
    constant StarGPU&        star  [[ buffer(1) ]],
    constant CameraUniforms& cam   [[ buffer(2) ]],
    constant LabelUniforms&  L     [[ buffer(3) ]]
) {
    const float2 corners[4] = { float2(-1,-1), float2( 1,-1), float2(-1, 1), float2( 1, 1) };

    float coronaMult = 4.9 * star.coronaScale;
    float halfSize = star.radius * coronaMult;
    float2 c = corners[vid];
    float3 worldPos = star.position.xyz
                    + L.cameraRight.xyz * (c.x * halfSize)
                    + L.cameraUp.xyz    * (c.y * halfSize);

    StarHaloOut out;
    out.clipPos    = cam.viewProjection * float4(worldPos, 1.0);
    out.uv         = (c + 1.0) * 0.5;
    out.coronaMult = coronaMult;
    return out;
}

fragment float4 starHaloFragment(
    StarHaloOut              in     [[ stage_in ]],
    constant StarGPU&        star   [[ buffer(1) ]],
    constant MotionUniforms& motion [[ buffer(3) ]]
) {
    float2 c = in.uv - 0.5;
    float  r = length(c) * 2.0;
    if (r > 1.0) discard_fragment();

    float angle = atan2(c.y, c.x);
    float t     = motion.time;
    float s     = star.seed;
    float sphereR = 1.0 / in.coronaMult;

    if (r < sphereR) return float4(0.0);

    // Distance from sphere edge across the corona band
    float ir = saturate((r - sphereR) / (1.0 - sphereR));
    float shellStart = smoothstep(0.02, 0.12, ir);

    // Limb glow uses the limb color so it matches the surface edge seamlessly
    float limbGlow = shellStart * exp(-ir * ir * 7.0);

    // Wispy plasma tendrils — speed and amount scale with chaos & coronaScale
    float chaos    = 1.0 - star.stability;
    float wispRate = 0.06 + chaos * 0.18;
    float wispNoise = ridgedFbm5(float3(angle * 2.6 + t * wispRate + s,
                                        ir * 3.2,
                                        t * (wispRate * 1.4)));
    float wispDetail = mix(0.4, 1.0, star.coronaScale - 0.7);  // bigger corona ⇒ more detail
    float wisps = (wispNoise * (0.40 + chaos * 0.16) * wispDetail + 0.24) * shellStart;

    float atmo = shellStart * exp(-ir * ir * 2.4);

    // Looping prominences — frequency, reach, and opacity driven by flareDensity.
    // The old curve mostly changed an already-tiny mask, so the slider felt inert.
    float prom = 0.0;
    float flare = saturate(star.flareDensity);
    float promReach = mix(1.05, 2.25, flare);
    if (r < sphereR * (1.0 + promReach)) {
        float pr = saturate((r - sphereR) / (sphereR * promReach));
        float angularFreq = mix(2.2, 10.5, flare);
        float promNoise = fbm5(float3(angle * angularFreq + s * 4.3,
                                      t * mix(0.10, 0.24, flare),
                                      pr * mix(2.0, 6.5, flare)));
        float exponent  = mix(12.0, 2.6, flare);
        float threshold = mix(0.88, 0.36, flare);
        float promMask  = pow(saturate(promNoise * 0.5 + 0.5), exponent);
        float activity  = (sin(t * 0.16 + angle * 3.0 + s * 6.7) * 0.5 + 0.5)
                        * (sin(t * 0.11 - angle * 2.0 + s * 2.1) * 0.5 + 0.5);
        float radialShape = pow(sin(pr * 3.14159), mix(2.4, 0.85, flare));
        prom = promMask * max(0.0, activity * 1.35 - threshold) * radialShape * shellStart;
        prom *= mix(0.15, 2.10, flare);
    }

    // Composition uses the browser palette directly:
    //   limb glow   = limb color   (continues the surface edge)
    //   atmosphere  = mid color    (the wider warm wash)
    //   prominences = accent color (visual pops in the user's accent hue)
    float3 warmLimb = mix(solarLimbColor(), star.limbColor.xyz, 0.24);
    float3 warmAtmo = mix(solarMidColor(),  star.midColor.xyz,  0.18);
    float3 promTint = mix(float3(1.00, 0.72, 0.38), star.accentColor.xyz, 0.22);
    float3 col  = warmLimb * limbGlow * 0.22
                + warmAtmo * atmo * wisps * 0.18
                + promTint * prom * 0.74;

    col *= temperatureTint(star.temperature);

    float pulse = 0.96 + 0.04 * sin(t * star.pulseRate + star.phase);
    col *= min(star.intensity * pulse, 1.01) * 0.42;

    float lum = max(col.r, max(col.g, col.b));
    return float4(col, lum);
}

// ─────────────────────────────────────────────────────────────
// PASS 3 — minimal lens flare (atmospheric bleed only)
// ─────────────────────────────────────────────────────────────

struct LensFlareOut {
    float4 clipPos [[ position ]];
    float2 fragNDC;
    float2 starNDC;
};

vertex LensFlareOut starLensFlareVertex(
    uint                     vid   [[ vertex_id ]],
    constant StarGPU&        star  [[ buffer(1) ]],
    constant CameraUniforms& cam   [[ buffer(2) ]]
) {
    const float2 corners[4] = { float2(-1,-1), float2( 1,-1), float2(-1, 1), float2( 1, 1) };

    float4 starClip = cam.viewProjection * float4(star.position.xyz, 1.0);
    float2 starNDC  = starClip.xy / max(starClip.w, 0.0001);

    LensFlareOut out;
    out.clipPos = float4(corners[vid], 0.999, 1.0);
    out.fragNDC = corners[vid];
    out.starNDC = starNDC;
    return out;
}

fragment float4 starLensFlareFragment(
    LensFlareOut                in     [[ stage_in ]],
    constant StarGPU&           star   [[ buffer(1) ]],
    constant MotionUniforms&    motion [[ buffer(3) ]],
    constant LensFlareUniforms& U      [[ buffer(4) ]]
) {
    float aspect = U.screenSize.x / max(U.screenSize.y, 1.0);
    float2 d     = in.fragNDC - in.starNDC;
    float2 dCorr = float2(d.x * aspect, d.y);
    float  dist  = length(dCorr);

    // Pure soft atmospheric bleed — no rays, no streaks, no bokeh.
    float radial = exp(-dist * dist * (1.22 / max(star.coronaScale, 0.48))) * 0.018;

    float pulse = 0.96 + 0.04 * sin(motion.time * star.pulseRate + star.phase);
    float intensity = radial * star.intensity * pulse * 0.28;

    // Tint = browser limb color (matches what the user sees around the star body)
    float3 tint = mix(solarLimbColor(), star.midColor.xyz, 0.16);
    tint *= temperatureTint(star.temperature);

    return float4(tint * intensity, intensity);
}
