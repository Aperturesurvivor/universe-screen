// Layer 2 — Rendering: billboarded text labels above any labelled body.
// Body-kind agnostic: takes generic LabelTarget = (position, radius) tuples.
#include <metal_stdlib>
using namespace metal;

struct LabelTarget {
    float4 positionAndRadius;   // .xyz = anchor, .w = radius
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

struct LabelOut {
    float4 clipPos [[ position ]];
    float2 uv;
    uint   slice;
};

vertex LabelOut labelVertex(
    uint                       vid       [[ vertex_id ]],
    uint                       iid       [[ instance_id ]],
    constant LabelTarget*      targets   [[ buffer(1) ]],
    constant CameraUniforms&   cam       [[ buffer(2) ]],
    constant LabelUniforms&    L         [[ buffer(3) ]],
    constant float2*           pillFracs [[ buffer(4) ]]
) {
    const float2 corners[4] = { float2(-1,-1), float2( 1,-1), float2(-1, 1), float2( 1, 1) };
    const float2 uvs[4]     = { float2( 0, 1), float2( 1, 1), float2( 0, 0), float2( 1, 0) };

    LabelTarget t = targets[iid];
    float3 pos    = t.positionAndRadius.xyz;
    float  radius = t.positionAndRadius.w;

    float widthFrac  = pillFracs[iid].x;
    float heightFrac = max(pillFracs[iid].y, 1e-3);

    // Quad height is constant in world units; width matches the pill's actual
    // aspect ratio inside the texture so short and long names look proportional.
    float halfH = L.worldHeight * 0.5;
    float halfW = halfH * L.layerAspect * (widthFrac / heightFrac);

    // Anchor scales with the pill's height so longer pills don't overlap the planet.
    float3 anchor = pos + L.cameraUp.xyz * (radius + 7.0 + halfH);

    float2 c = corners[vid];
    float3 worldPos = anchor
                    + L.cameraRight.xyz * (c.x * halfW)
                    + L.cameraUp.xyz    * (c.y * halfH);

    // Crop UV to just the centred pill region in the texture.
    float2 origUV = uvs[vid];
    float2 cropOffset = float2((1.0 - widthFrac) * 0.5, (1.0 - heightFrac) * 0.5);
    float2 cropSize   = float2(widthFrac, heightFrac);
    float2 finalUV    = cropOffset + origUV * cropSize;

    LabelOut out;
    out.clipPos = cam.viewProjection * float4(worldPos, 1.0);
    out.uv      = finalUV;
    out.slice   = iid;
    return out;
}

fragment float4 labelFragment(
    LabelOut             in    [[ stage_in ]],
    texture2d_array<float> atlas [[ texture(0) ]]
) {
    constexpr sampler s(mag_filter::linear,
                        min_filter::linear,
                        mip_filter::linear,
                        address::clamp_to_edge);
    float4 col = atlas.sample(s, in.uv, in.slice);
    if (col.a < 0.02) discard_fragment();
    return col;
}
