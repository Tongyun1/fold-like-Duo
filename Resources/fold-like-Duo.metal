#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct EffectUniforms {
    float progress;
    float topScale;
    float maxBlur;
    float falloff;
    float darkening;
    float frost;
    float reducedMotion;
    float maxLod;
};

kernel void blurDownsample(texture2d<float, access::sample> source [[texture(0)]],
                           texture2d<float, access::write> target [[texture(1)]],
                           constant uint &horizontal [[buffer(0)]],
                           uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= target.get_width() || xy.y >= target.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(xy) + 0.5) / float2(target.get_width(), target.get_height());
    float2 axis = horizontal
        ? float2(1.0 / source.get_width(), 0.0)
        : float2(0.0, 1.0 / source.get_height());
    const float offsets[3] = { 1.4584295, 3.4039848, 5.3518058 };
    const float weights[3] = { 0.2393373, 0.1394403, 0.0527110 };
    float4 color = source.sample(s, uv) * 0.1370228;
    for (int index = 0; index < 3; ++index) {
        color += (source.sample(s, uv + offsets[index] * axis)
               +  source.sample(s, uv - offsets[index] * axis)) * weights[index];
    }
    target.write(color, xy);
}

vertex VertexOut effectVertex(uint id [[vertex_id]],
                              constant EffectUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    float2 corner = corners[id];
    VertexOut out;
    // Always cover the full display. Perspective is applied to the texture in
    // the fragment stage so the fold never exposes empty side regions.
    out.position = float4(corner, 0.0, 1.0);
    out.uv = float2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5);
    return out;
}

fragment float4 effectFragment(VertexOut in [[stage_in]],
                               texture2d<float> desktop [[texture(0)]],
                               constant EffectUniforms &u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized,
                        address::clamp_to_edge,
                        filter::linear,
                        mip_filter::linear);
    float progress = clamp(u.progress, 0.0, 1.0);
    float farEdge = clamp(1.0 - in.uv.y, 0.0, 1.0);
    float ramp = pow(farEdge, clamp(u.falloff, 0.1, 4.0));
    float radius = max(u.maxBlur, 0.0) * progress * ramp;
    float lod = radius < 0.35 ? 0.0 : clamp(log2(max(radius, 1.0)), 0.0, u.maxLod);

    // Pinch the captured desktop toward the far edge while keeping both outer
    // boundaries fixed. This maps the entire source continuously across the
    // entire display, avoiding black or transparent side wedges.
    float geometryStrength = mix(1.0, 0.32, clamp(u.reducedMotion, 0.0, 1.0));
    float perspective = max(1.0 / max(u.topScale, 0.5) - 1.0, 0.0);
    float pinch = perspective * geometryStrength * pow(farEdge, 1.15);
    float centeredX = in.uv.x * 2.0 - 1.0;
    float warpedX = centeredX * (1.0 + pinch * (1.0 - centeredX * centeredX));

    // Core Image uploads with a bottom-left origin; farEdge keeps it upright.
    float2 sampleUV = float2(clamp(warpedX * 0.5 + 0.5, 0.0, 1.0), farEdge);
    float3 color = desktop.sample(s, sampleUV, level(lod)).rgb;

    float localStrength = progress * ramp;
    color *= 1.0 - clamp(u.darkening, 0.0, 0.8) * localStrength;
    color = mix(color, float3(0.84, 0.89, 0.96), clamp(u.frost, 0.0, 0.6) * localStrength);

    float edgeDistance = min(in.uv.x, 1.0 - in.uv.x);
    float edgeWidth = 0.012 + 0.10 * pow(progress, 0.75) * (0.2 + 0.8 * pow(farEdge, 1.25));
    float edgeShade = exp(-pow(edgeDistance / max(edgeWidth, 0.001), 2.0));
    color *= 1.0 - 0.55 * pow(progress, 0.7) * pow(farEdge, 1.25) * edgeShade;

    return float4(color, 1.0);
}
