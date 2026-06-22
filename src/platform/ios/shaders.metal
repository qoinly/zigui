#include <metal_stdlib>
using namespace metal;

// iOS frosted-glass for the floating tab bar - kept in the iOS platform dir, separate
// from the shared macOS shaders. A capsule quad samples a pre-blurred copy of the
// backdrop (a real Gaussian frost), lightens it, and masks it to a rounded capsule.

struct FrostUniform {
    float4 rect;     // x, y, w, h of the capsule, in pixels
    float2 viewport; // drawable size, pixels
    float corner;    // corner radius, pixels (h/2 = a capsule)
    float tint;      // dark-mix amount (0 = clear blur, 1 = dark)
    float strength;  // overall opacity: 0 = invisible, 1 = full frost
    float pad0;
    float pad1;
    float pad2;
};

struct FrostOut {
    float4 position [[position]];
    float2 screen;     // pixel coords
    uint idx [[flat]]; // which frost rect this instance is
};

vertex FrostOut frost_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant FrostUniform* us [[buffer(0)]]
) {
    constant FrostUniform& u = us[iid];
    float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1),
    };
    float2 px = u.rect.xy + corners[vid] * u.rect.zw;
    FrostOut out;
    out.position = float4(px.x / u.viewport.x * 2.0 - 1.0, 1.0 - px.y / u.viewport.y * 2.0, 0, 1);
    out.screen = px;
    out.idx = iid;
    return out;
}

static float sd_round_box(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

fragment float4 frost_fragment(
    FrostOut in [[stage_in]],
    texture2d<float> blurred [[texture(0)]],
    constant FrostUniform* us [[buffer(0)]]
) {
    constant FrostUniform& u = us[in.idx];
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 col = blurred.sample(s, in.screen / u.viewport); // the frost = blurred backdrop
    col.rgb = mix(col.rgb, float3(0.09), u.tint);          // darken into a smoky glass
    float2 center = u.rect.xy + u.rect.zw * 0.5;
    float2 hs = u.rect.zw * 0.5;
    float2 p = in.screen - center;
    float sd = sd_round_box(p, hs, u.corner);
    float d = -sd; // depth inside from the rim
    // A faint bright lip on the inner top edge for a glassy highlight.
    float rim = clamp(1.0 - d / 2.5, 0.0, 1.0) * clamp(-p.y / hs.y, 0.0, 1.0);
    col.rgb += rim * 0.12;
    float a = clamp(0.5 - sd, 0.0, 1.0); // anti-aliased capsule edge
    return float4(col.rgb, a * u.strength); // strength fades the whole frost in/out
}
