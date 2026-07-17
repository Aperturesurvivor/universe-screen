// Layer 2 — Rendering: Sebastian Lague–style procedural planet shader.
// Vertex stage: kinematic motion + multi-octave simplex displacement.
// Fragment stage: elevation-based biome coloring + flat-shaded face normals.
#include <metal_stdlib>
#include "noise.h"
using namespace metal;

struct PlanetGPU {
    float3 position;
    float  radius;
    float  phase;
    uint   biomeIndex;
    float  spinSpeed;
};

struct MeshVertex {
    float3 position;
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

struct PlanetFocusUniform {
    uint continentCount;
    float continentBlend;
    uint _pad1;
    uint _pad2;
};

struct VertexOut {
    float4 clipPos    [[ position ]];
    float3 worldPos;

    float3 sphereNormal;
    float  elevation;
    float  landMask;
    uint   biome;
    float  phase;
};

static inline float3 rotateY(float3 p, float a) {
    float s = sin(a), c = cos(a);
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

static inline float terrainHeight(float3 unit, float seed, float reliefScale, thread float& landMask) {
    float3 baseP = unit * 2.05 + float3(seed * 17.31, seed * 7.91, seed * 3.13);
    float continents = fbm5(baseP) * 0.5 + 0.5;

    float3 warp = float3(
        fbm5(unit * 1.8 + seed * 0.17),
        fbm5(unit.zxy * 1.9 + seed * 0.31),
        fbm5(unit.yzx * 1.7 + seed * 0.47)
    ) * 0.22;
    float land = fbm5(unit * 2.55 + warp + seed * 2.1) * 0.5 + 0.5;

    landMask = smoothstep(0.46, 0.58, continents * 0.72 + land * 0.28);

    float shelves = smoothstep(0.42, 0.68, continents);
    float3 ridgeP = unit * 8.5 + warp * 2.4 + seed * 4.9;
    float ridges = ridgedFbm5(ridgeP);
    float3 detailP = unit * 19.0 + seed * 7.3;
    float detail = ridgedFbm5(detailP);

    float terrain = landMask * (0.010 + shelves * 0.026 + ridges * ridges * 0.030 + detail * 0.008);
    float seaFloor = (1.0 - landMask) * (0.0025 * shelves);
    return (terrain + seaFloor) * reliefScale;
}

vertex VertexOut planetVertex(
    uint                       vid       [[ vertex_id ]],
    uint                       iid       [[ instance_id ]],
    constant MeshVertex*       verts     [[ buffer(0) ]],
    constant PlanetGPU*        planets   [[ buffer(1) ]],
    constant CameraUniforms&   cam       [[ buffer(2) ]],
    constant MotionUniforms&   motion    [[ buffer(3) ]],
    constant PlanetFocusUniform& focus    [[ buffer(4) ]]
) {
    PlanetGPU pl = planets[iid];

    float t  = motion.time;
    float ph = pl.phase;
    float3 wobble = float3(
        sin(t * 0.30 + ph * 1.7) * 4.0,
        sin(t * 0.45 + ph * 0.9) * 0.0,
        cos(t * 0.35 + ph * 1.3) * 4.0
    ) * motion.motionAmount;

    float3 center = pl.position + wobble;

    float spin = t * pl.spinSpeed * 0.34 + ph;
    float3 unit = rotateY(verts[vid].position, spin);
    float landMask = 0.0;
    float reliefScale = focus.continentBlend > 0.001 ? 0.0 : 1.0;
    float  elev = terrainHeight(unit, pl.phase, reliefScale, landMask);
    float  r    = pl.radius * (1.0 + elev);
    float3 worldPos = center + unit * r;

    VertexOut out;
    out.clipPos      = cam.viewProjection * float4(worldPos, 1.0);
    out.worldPos     = worldPos;
    out.sphereNormal = unit;
    out.elevation    = elev;
    out.landMask     = landMask;
    out.biome        = pl.biomeIndex;
    out.phase        = pl.phase;
    return out;
}

struct Palette {
    float3 dWater, sWater, beach, low, high, peak;
    float3 atmo, cloud, night;
};

static inline Palette paletteFor(uint biome) {
    switch (biome) {
    case 0:
        return { float3(0.05,0.18,0.45), float3(0.20,0.45,0.75),
                 float3(0.92,0.83,0.55), float3(0.20,0.55,0.20),
                 float3(0.40,0.50,0.25), float3(0.95,0.95,0.98),
                 float3(0.38,0.62,1.00), float3(0.92,0.96,1.00),
                 float3(0.18,0.55,0.92) };
    case 1:
        return { float3(0.10,0.18,0.30), float3(0.30,0.40,0.55),
                 float3(0.95,0.85,0.60), float3(0.85,0.70,0.40),
                 float3(0.65,0.50,0.30), float3(0.85,0.78,0.65),
                 float3(0.88,0.62,0.36), float3(1.00,0.91,0.76),
                 float3(0.95,0.46,0.18) };
    case 2:
        return { float3(0.02,0.10,0.30), float3(0.10,0.35,0.65),
                 float3(0.80,0.85,0.90), float3(0.55,0.75,0.85),
                 float3(0.40,0.55,0.65), float3(0.95,0.97,1.00),
                 float3(0.52,0.78,1.00), float3(0.95,0.98,1.00),
                 float3(0.35,0.68,1.00) };
    case 3:
        return { float3(0.15,0.05,0.05), float3(0.50,0.15,0.10),
                 float3(0.85,0.50,0.30), float3(0.70,0.30,0.20),
                 float3(0.45,0.20,0.15), float3(0.90,0.80,0.70),
                 float3(1.00,0.44,0.24), float3(1.00,0.72,0.48),
                 float3(1.00,0.25,0.08) };
    case 5:
        return { float3(0.10,0.08,0.02), float3(0.35,0.25,0.05),
                 float3(0.95,0.85,0.45), float3(0.85,0.75,0.30),
                 float3(0.60,0.50,0.20), float3(1.00,0.95,0.70),
                 float3(1.00,0.86,0.38), float3(1.00,0.96,0.72),
                 float3(1.00,0.78,0.18) };
    default:
        return { float3(0.08,0.10,0.15), float3(0.20,0.25,0.35),
                 float3(0.55,0.55,0.55), float3(0.45,0.45,0.50),
                 float3(0.30,0.30,0.35), float3(0.90,0.90,0.95),
                 float3(0.60,0.68,0.82), float3(0.90,0.92,0.96),
                 float3(0.62,0.70,0.88) };
    }
}

static inline float hash11(float n) {
    return fract(sin(n) * 43758.5453123);
}

static inline float3 seedColor(float seed, float offset, float3 a, float3 b) {
    float t = hash11(seed * 37.17 + offset);
    return mix(a, b, t);
}

static inline float folderContinentMask(float3 unit,
                                        float seed,
                                        constant PlanetFocusUniform& focus,
                                        constant float4* continentDirs,
                                        thread float& folderTone) {
    float mask = 0.0;
    folderTone = 0.0;
    uint continentCount = min(focus.continentCount, 32u);
    for (uint i = 0; i < continentCount; ++i) {
        float3 anchor = normalize(continentDirs[i].xyz);
        float angularRadius = clamp(continentDirs[i].w, 0.10, 0.68);
        float3 t1 = normalize(float3(anchor.z + 0.19, 0.11, -anchor.x + 0.23));
        float3 t2 = normalize(cross(anchor, t1));

        float shaped = 0.0;
        for (uint l = 0; l < 7u; ++l) {
            float lf = float(l);
            float angle = seed * 2.7 + float(i) * 1.91 + lf * 2.39996;
            float spread = (l == 0u) ? 0.0 : angularRadius * (0.30 + 0.22 * hash11(seed + float(i) * 9.0 + lf));
            float3 lobeDir = normalize(anchor
                + t1 * cos(angle) * spread
                + t2 * sin(angle) * spread);
            float lobeRadius = angularRadius * ((l == 0u) ? 0.74 : (0.28 + 0.24 * hash11(seed * 3.0 + float(i) + lf)));
            float d = dot(unit, lobeDir);
            float edgeNoise = fbm5(unit * (4.2 + lf * 0.7) + seed * 3.1 + float(i) * 1.73 + lf) * 0.5 + 0.5;
            float detailNoise = fbm5(unit * (11.0 + lf * 1.9) + seed * 8.0 + float(i) * 2.41) * 0.5 + 0.5;
            float noisyRadius = lobeRadius + (edgeNoise - 0.5) * 0.120 + (detailNoise - 0.5) * 0.055;
            float threshold = cos(noisyRadius);
            float lobe = smoothstep(threshold - 0.036, threshold + 0.020, d);
            shaped = max(shaped, lobe);
        }
        float islandNoise = fbm5(unit * 18.0 + seed * 4.8 + float(i) * 3.3) * 0.5 + 0.5;
        float islands = smoothstep(cos(angularRadius * 0.70), cos(angularRadius * 0.48),
                                   dot(unit, anchor) + (islandNoise - 0.5) * 0.10) * 0.22;
        shaped = max(shaped, islands);
        mask = max(mask, shaped);
        folderTone = max(folderTone, shaped * (float(i) + 1.0) / max(1.0, float(continentCount)));
    }
    return saturate(mask);
}

struct PlanetSurfaceLayers {
    float water;
    float shelf;
    float coast;
    float land;
    float mountains;
    float polar;
    float folderTone;
};

static inline PlanetSurfaceLayers naturalSurfaceLayers(float landMask, float elevation, float3 unit) {
    PlanetSurfaceLayers layers;
    layers.land = smoothstep(0.46, 0.72, landMask);
    layers.water = 1.0 - smoothstep(0.18, 0.52, landMask);
    layers.shelf = smoothstep(0.10, 0.46, landMask) * (1.0 - smoothstep(0.48, 0.76, landMask));
    layers.coast = smoothstep(0.34, 0.56, landMask) * (1.0 - smoothstep(0.58, 0.82, landMask));
    layers.mountains = smoothstep(0.052, 0.115, elevation) * layers.land;
    layers.polar = pow(abs(unit.y), 3.2);
    layers.folderTone = 0.0;
    return layers;
}

static inline PlanetSurfaceLayers focusedSurfaceLayers(float3 unit,
                                                       float seed,
                                                       float elevation,
                                                       constant PlanetFocusUniform& focus,
                                                       constant float4* continentDirs) {
    float tone = 0.0;
    float continent = folderContinentMask(unit, seed, focus, continentDirs, tone);

    PlanetSurfaceLayers layers;
    layers.land = smoothstep(0.48, 0.76, continent);
    layers.water = 1.0 - smoothstep(0.12, 0.42, continent);
    layers.shelf = smoothstep(0.05, 0.42, continent) * (1.0 - smoothstep(0.45, 0.72, continent));
    layers.coast = smoothstep(0.30, 0.54, continent) * (1.0 - smoothstep(0.58, 0.86, continent));
    layers.mountains = 0.0;
    layers.polar = pow(abs(unit.y), 3.2) * layers.land;
    layers.folderTone = tone;
    return layers;
}

static inline float3 colorFromLayers(PlanetSurfaceLayers layers,
                                     Palette pal,
                                     float3 unit,
                                     float seed,
                                     bool focused) {
    float colorNoise = fbm5(unit * 11.0 + seed * 6.1) * 0.5 + 0.5;
    if (focused) {
        float wetNoise = fbm5(unit * 8.0 + seed * 4.0) * 0.5 + 0.5;
        float3 oceanDeep = seedColor(seed, 1.0, pal.dWater * 0.72, pal.dWater * 1.18 + pal.night * 0.10);
        float3 oceanShelf = seedColor(seed, 2.0, pal.sWater * 0.70, pal.sWater * 1.20 + pal.atmo * 0.12);
        float3 beach = seedColor(seed, 3.0, pal.beach * 0.80, pal.beach * 1.16);
        float3 landA = seedColor(seed, 4.0, pal.low * 0.78, pal.high * 1.08);
        float3 landB = seedColor(seed, 5.0, pal.high * 0.82, pal.peak * 0.86 + pal.low * 0.22);
        float3 landColor = mix(landA, landB, smoothstep(0.05, 0.95, layers.folderTone));
        landColor *= mix(0.92, 1.08, wetNoise);
        float3 color = mix(oceanDeep, oceanShelf, layers.shelf);
        color = mix(color, beach, layers.coast * 0.78);
        color = mix(color, landColor, layers.land);
        color = mix(color, float3(0.94, 0.94, 0.90), layers.polar * 0.42);
        return color * mix(0.96, 1.05, colorNoise);
    }

    float3 color = mix(pal.dWater, pal.sWater, layers.shelf);
    color = mix(color, pal.beach, layers.coast);
    color = mix(color, mix(pal.low, pal.high, smoothstep(0.15, 0.95, colorNoise)), layers.land);
    color = mix(color, pal.peak, layers.mountains + layers.polar * layers.land * 0.42);
    return color * mix(0.88, 1.12, colorNoise);
}

fragment float4 planetFragment(
    VertexOut                  in   [[ stage_in ]],
    constant CameraUniforms&   cam  [[ buffer(2) ]],
    constant MotionUniforms&   motion [[ buffer(3) ]],
    constant PlanetFocusUniform& focus [[ buffer(4) ]],
    constant float4* continentDirs [[ buffer(5) ]]
) {
    Palette pal = paletteFor(in.biome);

    float e = in.elevation;
    float3 unit = normalize(in.sphereNormal);
    bool focused = focus.continentCount > 0 && focus.continentBlend > 0.001;
    if (focused && unit.y < -0.992) {
        discard_fragment();
    }
    PlanetSurfaceLayers layers;
    if (focused) {
        layers = focusedSurfaceLayers(unit, in.phase, e, focus, continentDirs);
    } else {
        layers = naturalSurfaceLayers(in.landMask, e, unit);
    }
    float land = layers.land;
    float3 albedo = colorFromLayers(layers, pal, unit, in.phase, focused);

    float3 faceN   = normalize(cross(dfdx(in.worldPos), dfdy(in.worldPos)));
    float3 smoothN = unit;
    float normalRelief = focused ? 0.0 : 0.22;
    float blend = smoothstep(0.045, 0.14, e) * land * normalRelief;
    float3 N = normalize(mix(smoothN, faceN, blend));

    float3 L = normalize(cam.lightPos.xyz - in.worldPos);
    float3 V = normalize(cam.cameraPos.xyz - in.worldPos);
    float3 H = normalize(L + V);

    float NdotL = max(dot(N, L), 0.0);
    float smoothNdotL = max(dot(smoothN, L), 0.0);
    float ambient = 0.055;

    float ocean = 1.0 - smoothstep(0.16, 0.54, land);
    float fresnel = pow(1.0 - max(dot(smoothN, V), 0.0), 4.0);
    float spec = pow(max(dot(N, H), 0.0), mix(18.0, 72.0, ocean)) * ocean * (0.20 + 1.15 * smoothNdotL);

    // Broad cloud language. These aren't separate geometry, but they give the
    // planets a more premium, readable surface at desktop scale.
    float cloudTime = motion.time;
    float3 cloudP = unit * 4.6
                  + float3(cloudTime * 0.030 + in.phase * 5.1,
                           cloudTime * 0.012,
                           in.phase * 9.7);
    float belts = sin((unit.y * 7.0 + fbm5(unit * 3.2 + in.phase) * 1.4) + in.phase * 1.7) * 0.5 + 0.5;
    float cloudLarge = ridgedFbm5(cloudP);
    float cloudFine  = ridgedFbm5(cloudP * 2.6 + float3(0.0, cloudTime * 0.018, 0.0));
    float cloudMask  = smoothstep(0.56, 0.86, cloudLarge * 0.55 + cloudFine * 0.22 + belts * 0.23);
    cloudMask *= smoothstep(0.03, 0.24, land) * 0.70 + 0.30;
    if (focused) {
        cloudMask *= 0.22;
    }
    float cloudShadow = cloudMask * mix(0.03, 0.16, smoothNdotL);

    // Atmospheric scattering rim — slightly warmer toward the lit side.
    float rimT  = pow(1.0 - max(dot(smoothN, V), 0.0), 2.6);
    float3 rimCool = focused
        ? seedColor(in.phase, 6.0, float3(0.34, 0.58, 0.88), float3(0.58, 0.86, 1.00))
        : pal.atmo;
    float3 rimWarm = float3(1.00, 0.85, 0.55);
    float3 atmo    = mix(rimCool, rimWarm, smoothNdotL) * rimT * (0.50 + 0.34 * smoothNdotL);

    // Star-tinted warm light for direct illumination
    float3 sunTint = float3(1.00, 0.95, 0.82);
    float terminator = smoothstep(-0.04, 0.34, NdotL);
    float3 lit     = albedo * sunTint * (1.34 * terminator + 0.16 * smoothNdotL);

    // Nightside retains a little bounce and atmospheric readability so planets
    // still feel round and expensive rather than cut out.
    float nightRim = pow(1.0 - max(dot(N, V), 0.0), 4.2) * (1.0 - terminator);
    float3 bounce  = pal.night * 0.055 * (1.0 - terminator);
    float3 cloudColor = mix(pal.cloud * 0.82, float3(1.00, 0.99, 0.97), smoothNdotL);
    float cityNoise = fbm5(unit * 26.0 + in.phase * 8.0) * 0.5 + 0.5;
    float cityMask = focused ? 0.0 : smoothstep(0.78, 0.93, cityNoise) * land * (1.0 - layers.polar);
    float3 nightLights = pal.night * cityMask * pow(1.0 - terminator, 2.2) * 0.34;

    float3 color   = albedo * ambient + lit + spec + atmo + bounce;

    color = mix(color, color + pal.sWater * (0.10 + fresnel * 0.36), ocean * (0.35 + 0.45 * fresnel));
    color *= 1.0 - cloudShadow;
    color = mix(color, color + cloudColor * (0.14 + 0.28 * smoothNdotL), cloudMask * (0.16 + 0.24 * smoothNdotL));
    color += nightRim * mix(rimCool, rimWarm, 0.35) * 0.18;
    color += nightLights;
    if (focus.continentCount > 0 && focus.continentBlend < 0.999) {
        PlanetSurfaceLayers baseLayers = naturalSurfaceLayers(in.landMask, e, unit);
        float3 baseAlbedo = colorFromLayers(baseLayers, pal, unit, in.phase, false);
        float baseLand = baseLayers.land;
        float baseOcean = 1.0 - smoothstep(0.16, 0.54, baseLand);
        float3 baseLit = baseAlbedo * ambient + baseAlbedo * sunTint * (1.34 * terminator + 0.16 * smoothNdotL);
        baseLit = mix(baseLit, baseLit + pal.sWater * (0.10 + fresnel * 0.36), baseOcean * (0.35 + 0.45 * fresnel));
        color = mix(baseLit, color, smoothstep(0.0, 1.0, focus.continentBlend));
    }
    color = color / (color + 0.55);
    color = pow(color, float3(0.92));
    return float4(color, 1.0);
}
