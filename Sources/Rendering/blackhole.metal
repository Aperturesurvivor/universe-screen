// Black Hole — Phase 6, Trash. Intentionally simple.
//   horizon — opaque black sphere with a faint inner-rim glow.
//   glow    — additive billboard: thin bright photon ring + soft outer halo.
#include <metal_stdlib>
using namespace metal;

struct BlackHoleGPU {
    float4 position;     // .xyz world position
    float  radius;       // event horizon radius (world units = screen points)
    float  intensity;    // master brightness for ring + halo
    float  _pad0, _pad1;
};

struct MeshVertex {
    float3 position;
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

// ─────────────────────────────────────────────────────────────
// PASS 1 — event horizon (opaque sphere, solid black)
// ─────────────────────────────────────────────────────────────

struct HorizonOut {
    float4 clipPos [[ position ]];
    float3 unit;
    float3 worldPos;
};

vertex HorizonOut blackHoleHorizonVertex(
    uint                       vid    [[ vertex_id ]],
    constant MeshVertex*       verts  [[ buffer(0) ]],
    constant BlackHoleGPU&     bh     [[ buffer(1) ]],
    constant CameraUniforms&   cam    [[ buffer(2) ]]
) {
    float3 unit = verts[vid].position;
    float3 worldPos = bh.position.xyz + unit * bh.radius;

    HorizonOut out;
    out.clipPos  = cam.viewProjection * float4(worldPos, 1.0);
    out.unit     = unit;
    out.worldPos = worldPos;
    return out;
}

fragment float4 blackHoleHorizonFragment(
    HorizonOut               in     [[ stage_in ]],
    constant BlackHoleGPU&   bh     [[ buffer(1) ]],
    constant CameraUniforms& cam    [[ buffer(2) ]]
) {
    // Pure black, with a barely-there warm rim so the silhouette doesn't look
    // like a dead pixel — a quiet hint that something is *there*.
    float3 V = normalize(cam.cameraPos.xyz - in.worldPos);
    float NdotV = max(0.0, dot(normalize(in.unit), V));
    float rim = pow(1.0 - NdotV, 6.0);

    float3 col = float3(0.20, 0.10, 0.04) * rim * 0.04;
    return float4(col, 1.0);
}

// ─────────────────────────────────────────────────────────────
// PASS 2 — photon ring + soft outer halo
// Additive billboard quad facing the camera.
// ─────────────────────────────────────────────────────────────

struct GlowOut {
    float4 clipPos [[ position ]];
    float2 uv;          // [-1, 1]² across the billboard quad
    float  reach;       // billboard half-extent in units of bh.radius
};

vertex GlowOut blackHoleGlowVertex(
    uint                       vid    [[ vertex_id ]],
    constant BlackHoleGPU&     bh     [[ buffer(1) ]],
    constant CameraUniforms&   cam    [[ buffer(2) ]],
    constant LabelUniforms&    L      [[ buffer(3) ]]
) {
    const float2 corners[4] = { float2(-1,-1), float2( 1,-1), float2(-1, 1), float2( 1, 1) };

    // Compact billboard — just enough room for the photon ring + a soft halo.
    float reach    = 3.0;
    float halfSize = bh.radius * reach;

    float2 c = corners[vid];
    float3 worldPos = bh.position.xyz
                    + L.cameraRight.xyz * (c.x * halfSize)
                    + L.cameraUp.xyz    * (c.y * halfSize);

    GlowOut out;
    out.clipPos = cam.viewProjection * float4(worldPos, 1.0);
    out.uv      = c;
    out.reach   = reach;
    return out;
}

fragment float4 blackHoleGlowFragment(
    GlowOut                  in     [[ stage_in ]],
    constant BlackHoleGPU&   bh     [[ buffer(1) ]],
    constant MotionUniforms& motion [[ buffer(3) ]]
) {
    // r = distance from BH center, in units of bh.radius.
    float2 p = in.uv * in.reach;
    float  r = length(p);

    // Inside the event horizon — sphere already painted that region.
    if (r < 1.0) return float4(0.0);

    // Photon ring: thin bright band just outside the horizon.
    float ringR  = 1.04;
    float ringW  = 0.025;
    float ring   = exp(-pow((r - ringR) / ringW, 2.0));

    // Soft outer halo bloom — gentle warm glow that fades to nothing by the
    // edge of the billboard.
    float halo = exp(-r * r * 0.55) * 0.20;

    float3 ringCol = float3(1.00, 0.92, 0.78);
    float3 haloCol = float3(0.85, 0.55, 0.30);

    float3 col = ringCol * ring * 1.40
               + haloCol * halo;

    col *= bh.intensity;

    float lum = max(col.r, max(col.g, col.b));
    return float4(col, lum);
}
