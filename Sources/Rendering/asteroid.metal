// Asteroids — small lumpy rocks for desktop files. Reuses the unit sphere mesh.
#include <metal_stdlib>
#include "noise.h"
using namespace metal;

struct AsteroidGPU {
    float3 position;   // offset 0  (16 bytes incl pad)
    float  radius;     // offset 16
    float  phase;      // offset 20
    uint   variant;    // offset 24
    float  _pad;       // offset 28 → 32-byte stride
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

struct AsteroidOut {
    float4 clipPos    [[ position ]];
    float3 worldPos;
    float  bumpiness;     // 0..1, used for lighting & valley darkening
    uint   variant;
};

vertex AsteroidOut asteroidVertex(
    uint                       vid       [[ vertex_id ]],
    uint                       iid       [[ instance_id ]],
    constant MeshVertex*       verts     [[ buffer(0) ]],
    constant AsteroidGPU*      asteroids [[ buffer(1) ]],
    constant CameraUniforms&   cam       [[ buffer(2) ]],
    constant MotionUniforms&   motion    [[ buffer(3) ]]
) {
    AsteroidGPU a = asteroids[iid];

    float3 unit = verts[vid].position;

    // Heavy lumpy displacement — way more dramatic than planets
    float3 noisePos = unit * 4.0
                    + float3(a.phase * 7.31, a.phase * 13.7, a.phase * 5.91);
    float  n = fbm5(noisePos);              // [-1, 1]
    float  bumpiness = (n + 1.0) * 0.5;     // 0..1
    float  disp = (n * 0.35);               // up to ±35% radial wobble

    float3 displaced = unit * a.radius * (1.0 + disp);
    float3 worldPos  = a.position + displaced;

    AsteroidOut out;
    out.clipPos   = cam.viewProjection * float4(worldPos, 1.0);
    out.worldPos  = worldPos;
    out.bumpiness = bumpiness;
    out.variant   = a.variant;
    return out;
}

fragment float4 asteroidFragment(
    AsteroidOut                in   [[ stage_in ]],
    constant CameraUniforms&   cam  [[ buffer(2) ]]
) {
    // Three rock palettes
    float3 base;
    switch (in.variant % 3u) {
        case 0u: base = float3(0.50, 0.45, 0.40); break;  // grey
        case 1u: base = float3(0.55, 0.42, 0.30); break;  // brown
        default: base = float3(0.42, 0.40, 0.42); break;  // dark grey
    }

    // Darken valleys, brighten peaks
    float3 albedo = base * (0.65 + in.bumpiness * 0.55);

    // Flat-shaded face normal — matches Lague-style asteroids
    float3 N = normalize(cross(dfdx(in.worldPos), dfdy(in.worldPos)));
    float3 L = normalize(cam.lightPos.xyz - in.worldPos);
    float3 V = normalize(cam.cameraPos.xyz - in.worldPos);
    float NdotL = max(dot(N, L), 0.0);
    float rim = pow(1.0 - max(dot(N, V), 0.0), 3.2);
    float3 R = reflect(-L, N);
    float spec = pow(max(dot(R, V), 0.0), 18.0) * 0.18;

    float3 sunTint = float3(1.00, 0.92, 0.74);
    float3 color = albedo * (0.08 + 1.06 * NdotL) * sunTint;
    color += rim * float3(0.48, 0.34, 0.18) * 0.14;
    color += spec;
    return float4(color, 1.0);
}
