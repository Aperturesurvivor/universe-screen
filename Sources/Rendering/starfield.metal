// Procedural background + starfield. Both seeded and repeatable.
#include <metal_stdlib>
#include "noise.h"
using namespace metal;

struct BackgroundUniforms {
    float2 screenSize;
    float  time;
    float  seedLo;
    float  seedHi;
    // Sky personality — mirrored in BackgroundRenderer.swift / SkyParams.
    float  bandAngle;
    float  bandWidth;
    float  bandStrength;
    float  nebulaCount;
    float  shapeStyle;
    float  galaxyCount;
    float  paletteShift;
    float  dustAmount;
    float  grainAmount;
    float  overallTint;
    float  _pad;
};

struct BackgroundOut {
    float4 clipPos [[ position ]];
    float2 fragNDC;
    float2 uv;
};

static inline float hash11(float x) {
    return fract(sin(x * 91.3458 + 12.345) * 47453.5453);
}

// Deterministic 0..1 from (seedLo, seedHi, slot). One slot ≈ one independent roll.
static inline float srand(float seedLo, float seedHi, float slot) {
    float v = fract(sin(seedLo * 0.000913 + seedHi * 0.000317 + slot * 78.233) * 43758.5453);
    return fract(sin(v * 91.345 + slot * 12.789) * 47453.5453);
}

// Eight emission palettes — picked per-nebula via paletteShift + per-lobe roll.
// inner = bright core color, outer = falloff/edge color.
static inline void nebulaPalette(int idx, thread float3 &inner, thread float3 &outer) {
    switch (idx & 7) {
        case 0: inner = float3(0.82, 0.22, 0.36); outer = float3(0.30, 0.06, 0.14); break; // H-α pink
        case 1: inner = float3(0.22, 0.44, 0.92); outer = float3(0.05, 0.10, 0.30); break; // reflection blue
        case 2: inner = float3(0.22, 0.66, 0.52); outer = float3(0.04, 0.18, 0.20); break; // O-III teal
        case 3: inner = float3(0.94, 0.58, 0.22); outer = float3(0.32, 0.12, 0.04); break; // S-II gold
        case 4: inner = float3(0.60, 0.24, 0.82); outer = float3(0.18, 0.04, 0.30); break; // violet
        case 5: inner = float3(0.82, 0.20, 0.20); outer = float3(0.20, 0.02, 0.02); break; // crimson
        case 6: inner = float3(0.42, 0.76, 0.84); outer = float3(0.06, 0.18, 0.32); break; // ice
        default:inner = float3(0.94, 0.64, 0.74); outer = float3(0.32, 0.12, 0.20); break; // peach
    }
}

vertex BackgroundOut backgroundVertex(
    uint                        vid [[ vertex_id ]],
    constant BackgroundUniforms& U  [[ buffer(0) ]]
) {
    const float2 corners[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 p = corners[vid];

    BackgroundOut out;
    out.clipPos = float4(p, 0.9995, 1.0);
    out.fragNDC = p;
    out.uv      = (p + 1.0) * 0.5;
    return out;
}

fragment float4 backgroundFragment(
    BackgroundOut               in [[ stage_in ]],
    constant BackgroundUniforms& U [[ buffer(0) ]]
) {
    float2 p = in.fragNDC;
    float aspect = U.screenSize.x / max(U.screenSize.y, 1.0);
    float2 q = float2(p.x * aspect, p.y);

    float sLo  = U.seedLo;
    float sHi  = U.seedHi;
    float seed = sLo * 0.000001 + sHi * 0.0000003;

    int   nebulaCount  = int(U.nebulaCount);
    int   shapeStyle   = int(U.shapeStyle);
    int   galaxyCount  = int(U.galaxyCount);
    int   paletteShift = int(U.paletteShift);
    float dustAmount   = U.dustAmount;
    float grainAmount  = U.grainAmount;
    float overallTint  = U.overallTint;
    float bandStrength = U.bandStrength;
    float bandWidth    = U.bandWidth;
    float bandAngle    = U.bandAngle;

    // ---- Base deep-space gradient with subtle seeded global tint -------
    float radial = length(q);
    float vignette = smoothstep(1.55, 0.20, radial);
    float3 baseHueA = float3(0.004, 0.005, 0.018);
    float3 baseHueB = float3(0.008, 0.010, 0.026);
    float3 globalTint = mix(float3(0.001, 0.000, 0.004),
                            float3(0.004, 0.001, 0.001),
                            overallTint);
    float3 color = mix(baseHueA, baseHueB, vignette) + globalTint * (0.5 + 0.5 * vignette);

    // ---- Seeded nebula lobes ------------------------------------------
    float3 nebulaAccum     = float3(0.0);
    float  nebulaMask      = 0.0;
    float3 nebulaTintAccum = float3(0.0);
    float  tintWeight      = 1e-4;

    for (int i = 0; i < 7; ++i) {
        if (i >= nebulaCount) break;
        float fi = float(i) + 0.131;

        float2 anchor = float2(srand(sLo, sHi, 20.0 + fi),
                               srand(sLo, sHi, 40.0 + fi)) * 2.0 - 1.0;
        anchor.x *= aspect * 0.95;

        float scale  = mix(0.42, 1.45, srand(sLo, sHi, 60.0 + fi));
        float aniso  = mix(0.55, 1.85, srand(sLo, sHi, 80.0 + fi));
        float angle  = srand(sLo, sHi, 100.0 + fi) * 6.2831853;
        float ca = cos(angle), sa = sin(angle);
        float2 d0 = q - anchor * 0.78;
        float2 delta = float2(d0.x * ca - d0.y * sa,
                              d0.x * sa + d0.y * ca);
        delta.x /= aniso;
        delta.y *= aniso;

        float dn = length(delta) / scale;
        float falloff = exp(-dn * dn * 1.65);

        float3 sampleP = float3(delta * 1.3, seed * 0.7 + fi * 0.41);
        float body  = fbm5(sampleP * 1.45) * 0.5 + 0.5;
        float wisps = ridgedFbm5(sampleP * 2.1 + float3(0.0, 0.0, 7.1));
        float pocket;
        if (shapeStyle == 0) {
            // Soft billowy
            pocket = saturate(body * 0.78 + wisps * 0.22);
        } else if (shapeStyle == 1) {
            // Filamentary — emphasize ridges so wisps dominate
            pocket = saturate(body * 0.40 + wisps * 0.60);
        } else {
            // High-contrast pillars
            float k = saturate(body * 0.55 + wisps * 0.45);
            pocket = smoothstep(0.30, 0.95, k);
        }

        int idx = (paletteShift + i * 3 + int(srand(sLo, sHi, 120.0 + fi) * 8.0)) & 7;
        float3 innerC, outerC;
        nebulaPalette(idx, innerC, outerC);

        float densityCurve = pow(pocket, mix(1.4, 0.7, srand(sLo, sHi, 140.0 + fi)));
        float3 tint = mix(outerC, innerC, densityCurve);

        float intensity = mix(0.55, 1.30, srand(sLo, sHi, 160.0 + fi));
        nebulaAccum     += tint * pocket * falloff * intensity;
        nebulaMask      += pocket * falloff;
        nebulaTintAccum += innerC * falloff;
        tintWeight      += falloff;
    }
    nebulaMask = saturate(nebulaMask * 0.85);
    color += nebulaAccum * 0.36;
    float3 averagedTint = nebulaTintAccum / tintWeight;

    // ---- Dust lanes (cloud-shaped occlusion through nebulas) -----------
    float dust = fbm5(float3(q * float2(1.3, 2.0), seed + 17.3)) * 0.5 + 0.5;
    dust = smoothstep(0.40, 0.82, dust);
    color *= 1.0 - dust * nebulaMask * 0.28 * dustAmount;

    // ---- Galactic band — Milky-Way-like haze ---------------------------
    float2 bdir  = float2(cos(bandAngle), sin(bandAngle));
    float2 bperp = float2(-bdir.y, bdir.x);
    float bandPerp = dot(q, bperp);
    float bandMask = exp(-bandPerp * bandPerp / max(bandWidth * bandWidth, 1e-4));
    float bandFbm  = fbm5(float3(q * 1.6, seed + 23.0)) * 0.5 + 0.5;
    float bandRidg = ridgedFbm5(float3(q * float2(2.6, 1.1), seed + 3.7));
    float bandShape = mix(bandFbm, bandRidg * 0.85 + bandFbm * 0.30, bandStrength);
    float3 bandTint = mix(float3(0.05, 0.04, 0.07),
                          float3(0.07, 0.05, 0.10) + averagedTint * 0.06,
                          0.5);
    color += bandTint * bandMask * bandShape * (0.18 + 0.45 * bandStrength);

    // ---- Distant galaxies — bulge + disk + spiral arms / dust lane -----
    for (int g = 0; g < 3; ++g) {
        if (g >= galaxyCount) break;
        float fg = float(g) + 0.317;

        float2 c = float2(srand(sLo, sHi, 200.0 + fg) * 2.0 - 1.0,
                          srand(sLo, sHi, 220.0 + fg) * 2.0 - 1.0);
        c.x *= aspect * 0.90;

        float angle = srand(sLo, sHi, 240.0 + fg) * 6.2831853;
        float cAng = cos(angle), sAng = sin(angle);

        // Inclination: 0 = face-on, 1 = edge-on. Bias toward higher values so
        // most distant galaxies show a recognizable disc silhouette rather
        // than a round blob.
        float incline = pow(srand(sLo, sHi, 260.0 + fg), 0.7);
        float ar = 1.0 + incline * 5.0;                      // 1..6 aspect

        float sz = mix(0.08, 0.18, srand(sLo, sHi, 280.0 + fg));

        // Disc-plane coords: along major axis / across minor axis.
        float2 d0 = q - c;
        float2 dr = float2(d0.x * cAng - d0.y * sAng,
                           d0.x * sAng + d0.y * cAng);
        float along  = dr.x / sz;
        float across = dr.y / (sz / ar);                     // squash perpendicular
        float r2     = along * along + across * across;
        float radial = sqrt(r2);

        // Central bulge — bright, compact, isotropic in disc-plane coords.
        float bulge = exp(-r2 * 4.5);

        // Disk — long along major axis, thin perpendicular.
        float diskAlong = exp(-along * along * 0.55);
        float diskCross = exp(-across * across * 5.0);
        float disk      = diskAlong * diskCross;

        // Logarithmic spiral arms (visible only as the galaxy approaches face-on).
        float armPhase = atan2(across, along) * 2.0
                       + log(0.18 + r2) * 1.6;
        float armMod   = 0.55 + 0.45 * cos(armPhase);
        float arms     = mix(1.0, armMod, (1.0 - incline) * 0.80);

        // Dust lane — thin dark band along the major axis, only near edge-on.
        float laneVis = pow(incline, 4.0);
        float lane    = exp(-across * across * 70.0)
                      * smoothstep(2.4, 0.6, abs(along))
                      * laneVis;

        // Soft outer halo.
        float halo = exp(-radial * 1.4) * 0.18;

        // Color: warm yellow bulge, cool blueish disc; occasional redshift bias.
        float redshift  = srand(sLo, sHi, 300.0 + fg);
        float3 bulgeCol = mix(float3(1.00, 0.88, 0.62),
                              float3(1.05, 0.55, 0.32), redshift * redshift);
        float3 diskCol  = mix(float3(0.78, 0.86, 1.05),
                              float3(0.95, 0.82, 0.70), redshift);
        float3 gCol     = mix(diskCol, bulgeCol, smoothstep(0.0, 1.0, bulge));

        float bright = bulge * 1.9 + disk * 0.55 * arms + halo;
        bright *= 1.0 - lane * 0.78;

        color += gCol * bright * 0.42;
    }

    // ---- Stardust — sparse per-cell point grains -----------------------
    // Each cell hosts at most one tiny "star" placed at a randomized sub-cell
    // position, with brightness falling off with distance from that point —
    // so within a cell the value varies per pixel (no flat blocks).
    float dotA = 0.0;
    {
        const float scale = 56.0;
        float2 g  = q * scale + float2(seed * 1.71, seed * 0.93);
        float2 ci = floor(g);
        float2 cf = fract(g) - 0.5;                       // -0.5..0.5
        float h1 = hash11(ci.x * 37.13 + ci.y * 91.7 + seed * 0.31);
        float h2 = hash11(h1 + 4.71);
        float2 sub = (float2(h1, h2) - 0.5) * 0.7;
        float d2 = dot(cf - sub, cf - sub);
        float exists = step(0.88, h1) * (h1 - 0.88) / 0.12;
        dotA = exp(-d2 * 240.0) * exists * 0.55;
    }
    float dotB = 0.0;
    {
        const float scale = 140.0;
        float2 g  = q * scale + float2(seed * 3.7, seed * 5.1);
        float2 ci = floor(g);
        float2 cf = fract(g) - 0.5;
        float h1 = hash11(ci.x * 23.71 + ci.y * 77.3 + seed * 1.17);
        float h2 = hash11(h1 + 33.1);
        float2 sub = (float2(h1, h2) - 0.5) * 0.7;
        float d2 = dot(cf - sub, cf - sub);
        float exists = step(0.95, h1) * (h1 - 0.95) / 0.05;
        dotB = exp(-d2 * 800.0) * exists * 0.40;
    }

    float dustWeight = nebulaMask * 0.85 + bandMask * 0.40 + 0.15;
    float3 dustTint  = mix(float3(0.85, 0.90, 1.00), averagedTint * 1.5 + 0.2, 0.55);
    color += dustTint * (dotA + dotB) * dustWeight * grainAmount * 0.55;

    // ---- Final shaping -------------------------------------------------
    color = pow(max(color, float3(0.0)), float3(0.92));
    return float4(color, 1.0);
}

struct BackgroundTextureOut {
    float4 clipPos [[ position ]];
    float2 uv;
};

vertex BackgroundTextureOut backgroundTextureVertex(uint vid [[ vertex_id ]]) {
    const float2 corners[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    const float2 uvs[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };

    BackgroundTextureOut out;
    out.clipPos = float4(corners[vid], 0.9995, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 backgroundTextureFragment(
    BackgroundTextureOut in [[ stage_in ]],
    texture2d<float> background [[ texture(0) ]]
) {
    constexpr sampler s(mag_filter::linear,
                        min_filter::linear,
                        address::clamp_to_edge);
    return background.sample(s, in.uv);
}

struct StarPoint {
    float2 ndc;        // -1..1
    float  size;       // pixels
    float  brightness; // 0..1
    float  phase;      // for twinkle desync
    float  _pad;       // align to 16-byte boundaries (24 bytes ⇒ stride 24)
};

struct StarfieldUniforms {
    float2 screenSize;     // pixels — for converting size to NDC
    float  time;
    float  _pad;
};

struct StarfieldOut {
    float4 clipPos [[ position ]];
    float2 uv;             // 0..1 across the quad
    float  brightness;
    float  phase;
};

vertex StarfieldOut starfieldVertex(
    uint                          vid    [[ vertex_id ]],
    uint                          iid    [[ instance_id ]],
    constant StarPoint*           points [[ buffer(0) ]],
    constant StarfieldUniforms&   U      [[ buffer(1) ]]
) {
    const float2 corners[4] = { float2(-1,-1), float2( 1,-1), float2(-1, 1), float2( 1, 1) };

    StarPoint p = points[iid];
    float2 sizeNDC = float2(p.size) / max(U.screenSize, float2(1.0)) * 2.0;
    float2 ndc = p.ndc + corners[vid] * sizeNDC;

    StarfieldOut out;
    // z=0.99 keeps stars at the back of the depth range (orthographic — depth
    // disabled anyway, but it documents intent).
    out.clipPos    = float4(ndc, 0.99, 1.0);
    out.uv         = (corners[vid] + 1.0) * 0.5;
    out.brightness = p.brightness;
    out.phase      = p.phase;
    return out;
}

fragment float4 starfieldFragment(
    StarfieldOut                in [[ stage_in ]],
    constant StarfieldUniforms& U  [[ buffer(1) ]]
) {
    float2 c = in.uv - 0.5;
    float  d = length(c);
    if (d > 0.5) discard_fragment();
    float core    = 1.0 - smoothstep(0.10, 0.50, d);
    float halo    = 1.0 - smoothstep(0.18, 0.50, d);
    float twinkle = 0.72 + 0.28 * sin(U.time * 1.2 + in.phase);
    float a       = in.brightness * twinkle * (core * 0.85 + halo * 0.20);

    // Slight temperature variation so the sky isn't monochrome.
    float warm = fract(sin(in.phase * 13.7) * 43758.5453);
    float3 cool = float3(0.72, 0.82, 1.00);
    float3 warmTint = float3(1.00, 0.92, 0.80);
    float3 tint = mix(cool, warmTint, smoothstep(0.20, 0.85, warm));
    return float4(tint * a, a);
}
