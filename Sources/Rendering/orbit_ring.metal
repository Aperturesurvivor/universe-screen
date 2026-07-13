// Faint orbit-ring lines rendered as instanced line strips.
// One instance per planet; each instance draws SEG_COUNT+1 vertices that
// trace a full circle at the planet's orbit radius around the star center.
#include <metal_stdlib>
using namespace metal;

struct OrbitRingGPU {
    float4 center;  // star world position (xz used, y ignored)
    float  radius;
    float  alpha;
    float  _pad0;
    float  _pad1;
};

struct CameraUniforms {
    float4x4 viewProjection;
    float4   cameraPos;
    float4   lightPos;
};

struct RingVOut {
    float4 position [[position]];
    float  alpha;
};

constant int SEG_COUNT = 96;

vertex RingVOut orbitRingVertex(
    uint                    vid   [[vertex_id]],
    uint                    iid   [[instance_id]],
    constant OrbitRingGPU*  rings [[buffer(0)]],
    constant CameraUniforms& cam  [[buffer(1)]])
{
    float theta = float(vid) / float(SEG_COUNT) * (2.0 * M_PI_F);
    float3 wp   = float3(
        rings[iid].center.x + cos(theta) * rings[iid].radius,
        0.0,
        rings[iid].center.z + sin(theta) * rings[iid].radius);
    RingVOut out;
    out.position = cam.viewProjection * float4(wp, 1.0);
    out.alpha    = rings[iid].alpha;
    return out;
}

fragment float4 orbitRingFragment(RingVOut in [[stage_in]]) {
    return float4(0.55, 0.65, 1.0, in.alpha);
}
