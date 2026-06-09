#include <metal_stdlib>
using namespace metal;

float4 to_device_position(float2 pixel_pos, float2 viewport_size) {
    float2 ndc = (pixel_pos / viewport_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    return float4(ndc, 0.0, 1.0);
}

float rounded_rect_sdf(float2 pos, float2 half_size, float radius) {
    float2 d = abs(pos) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float pick_corner_radius(float2 pos, float4 corner_radii) {
    if (pos.x < 0.5) {
        return pos.y < 0.5 ? corner_radii.x : corner_radii.z;
    } else {
        return pos.y < 0.5 ? corner_radii.y : corner_radii.w;
    }
}

float4 compute_clip_distance(float2 pixel_pos, float4 clip_bounds) {
    return float4(
        pixel_pos.x - clip_bounds.x,
        clip_bounds.x + clip_bounds.z - pixel_pos.x,
        pixel_pos.y - clip_bounds.y,
        clip_bounds.y + clip_bounds.w - pixel_pos.y
    );
}

struct Quad {
    float4 bounds;
    float4 background;
    float4 corner_radii;
    float4 border_color;
    float4 border_widths;
    float4 transform;
    float4 clip_bounds;
};

struct QuadFragmentIn {
    float4 position [[position]];
    float4 background;
    float4 border_color;
    float2 quad_pos;
    float4 corner_radii;
    float4 border_widths;
    float2 quad_size;
};

struct QuadVertexOut {
    QuadFragmentIn frag;
    float clip_distance [[clip_distance]][4];
};

vertex QuadVertexOut quad_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant float2 *unit_vertices [[buffer(0)]],
    constant Quad *quads [[buffer(1)]],
    constant float2 *viewport_size [[buffer(2)]]
) {
    float2 unit_vertex = unit_vertices[vertex_id];
    Quad quad = quads[instance_id];

    float rotation = quad.transform.x;
    float scale_x = quad.transform.y;
    float scale_y = quad.transform.z;

    float2 center = quad.bounds.xy + quad.bounds.zw * 0.5;

    float2 centered = unit_vertex - 0.5;
    centered *= float2(scale_x, scale_y);

    float cos_r = cos(rotation);
    float sin_r = sin(rotation);
    float2 rotated = float2(
        centered.x * cos_r - centered.y * sin_r,
        centered.x * sin_r + centered.y * cos_r
    );

    float2 pixel_pos = center + rotated * quad.bounds.zw;

    QuadVertexOut out;
    out.frag.position = to_device_position(pixel_pos, *viewport_size);
    out.frag.background = quad.background;
    out.frag.border_color = quad.border_color;
    out.frag.quad_pos = unit_vertex;
    out.frag.corner_radii = quad.corner_radii;
    out.frag.border_widths = quad.border_widths;
    out.frag.quad_size = quad.bounds.zw;

    float4 clip = compute_clip_distance(pixel_pos, quad.clip_bounds);
    out.clip_distance[0] = clip.x;
    out.clip_distance[1] = clip.y;
    out.clip_distance[2] = clip.z;
    out.clip_distance[3] = clip.w;

    return out;
}

float pick_border_width(float2 center_pos, float4 widths) {
    if (abs(center_pos.y) > abs(center_pos.x)) {
        return center_pos.y < 0.0 ? widths.x : widths.z;
    } else {
        return center_pos.x > 0.0 ? widths.y : widths.w;
    }
}

fragment float4 quad_fragment(QuadFragmentIn in [[stage_in]]) {
    float2 half_size = in.quad_size * 0.5;
    float2 center_pos = (in.quad_pos - 0.5) * in.quad_size;

    float radius = pick_corner_radius(in.quad_pos, in.corner_radii);
    float border_width = pick_border_width(center_pos, in.border_widths);

    float outer_dist = rounded_rect_sdf(center_pos, half_size, radius);

    float inner_radius = max(0.0, radius - border_width);
    float2 inner_half_size = max(float2(0.0), half_size - border_width);
    float inner_dist = rounded_rect_sdf(center_pos, inner_half_size, inner_radius);

    float outer_alpha = 1.0 - smoothstep(-0.5, 0.5, outer_dist);

    bool has_border = (in.border_widths.x + in.border_widths.y +
                       in.border_widths.z + in.border_widths.w) > 0.0;

    if (!has_border) {
        return float4(in.background.rgb, in.background.a * outer_alpha);
    }

    float border_blend = smoothstep(-0.5, 0.5, inner_dist);

    float4 bg = in.background * (1.0 - border_blend);
    float4 border = in.border_color * border_blend;

    float4 color = bg + border;
    return float4(color.rgb, color.a * outer_alpha);
}

struct GlyphInstance {
    float2 position;
    float2 size;
    float2 uv_origin;
    float2 uv_size;
    float4 color;
    float4 clip_bounds;
};

struct TextFragmentIn {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

struct TextVertexOut {
    TextFragmentIn frag;
    float clip_distance [[clip_distance]][4];
};

vertex TextVertexOut text_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant float2 *unit_vertices [[buffer(0)]],
    constant GlyphInstance *glyphs [[buffer(1)]],
    constant float2 *viewport_size [[buffer(2)]]
) {
    float2 unit_pos = unit_vertices[vertex_id];
    GlyphInstance glyph = glyphs[instance_id];

    float2 pixel_pos = glyph.position + unit_pos * glyph.size;

    TextVertexOut out;
    out.frag.position = to_device_position(pixel_pos, *viewport_size);
    out.frag.uv = glyph.uv_origin + unit_pos * glyph.uv_size;
    out.frag.color = glyph.color;

    float4 clip = compute_clip_distance(pixel_pos, glyph.clip_bounds);
    out.clip_distance[0] = clip.x;
    out.clip_distance[1] = clip.y;
    out.clip_distance[2] = clip.z;
    out.clip_distance[3] = clip.w;

    return out;
}

fragment float4 text_fragment(
    TextFragmentIn in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlas_sampler [[sampler(0)]]
) {
    float alpha = atlas.sample(atlas_sampler, in.uv).r;
    return float4(in.color.rgb, in.color.a * alpha);
}

struct Polyline {
    float2 pos_a;
    float2 pos_b;
    float4 fill_color;
    float4 clip_bounds;
    float  baseline_y;
    float  gradient;
    float  _pad1;
    float  _pad2;
};

struct PolylineFragmentIn {
    float4 position [[position]];
    float4 fill_color;
};

struct PolylineVertexOut {
    PolylineFragmentIn frag;
    float clip_distance [[clip_distance]][4];
};

vertex PolylineVertexOut polyline_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant float2 *unit_vertices [[buffer(0)]],
    constant Polyline *segs [[buffer(1)]],
    constant float2 *viewport_size [[buffer(2)]]
) {
    float2 unit_pos = unit_vertices[vertex_id];
    Polyline seg = segs[instance_id];

    float2 top = mix(seg.pos_a, seg.pos_b, unit_pos.x);
    float2 bottom = float2(top.x, seg.baseline_y);
    float2 pixel_pos = mix(top, bottom, unit_pos.y);

    PolylineVertexOut out;
    out.frag.position = to_device_position(pixel_pos, *viewport_size);
    // unit_pos.y runs 0 at the line to 1 at the baseline; fade the alpha across
    // that span so a filled area can dissolve toward the axis (gradient = 1).
    float fade = mix(1.0, 1.0 - seg.gradient, unit_pos.y);
    out.frag.fill_color = float4(seg.fill_color.rgb, seg.fill_color.a * fade);

    float4 clip = compute_clip_distance(pixel_pos, seg.clip_bounds);
    out.clip_distance[0] = clip.x;
    out.clip_distance[1] = clip.y;
    out.clip_distance[2] = clip.z;
    out.clip_distance[3] = clip.w;

    return out;
}

fragment float4 polyline_fragment(PolylineFragmentIn in [[stage_in]]) {
    return in.fill_color;
}

struct LineSegment {
    float2 pos_a;
    float2 pos_b;
    float4 color;
    float4 clip_bounds;
    float thickness;
    float _pad0;
    float _pad1;
    float _pad2;
};

struct LineFragmentIn {
    float4 position [[position]];
    float4 color;
};

struct LineVertexOut {
    LineFragmentIn frag;
    float clip_distance [[clip_distance]][4];
};

vertex LineVertexOut line_segment_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant float2 *unit_vertices [[buffer(0)]],
    constant LineSegment *segs [[buffer(1)]],
    constant float2 *viewport_size [[buffer(2)]]
) {
    float2 unit_pos = unit_vertices[vertex_id];
    LineSegment seg = segs[instance_id];

    float2 dir = seg.pos_b - seg.pos_a;
    float len = length(dir);
    float2 norm_dir = len > 0.0 ? dir / len : float2(1.0, 0.0);
    float2 perp = float2(-norm_dir.y, norm_dir.x);
    float half_thick = seg.thickness * 0.5;

    float2 along = mix(seg.pos_a, seg.pos_b, unit_pos.x);
    float side = unit_pos.y * 2.0 - 1.0; // -1 or +1 across the line
    float2 pixel_pos = along + perp * side * half_thick;

    LineVertexOut out;
    out.frag.position = to_device_position(pixel_pos, *viewport_size);
    out.frag.color = seg.color;

    float4 clip = compute_clip_distance(pixel_pos, seg.clip_bounds);
    out.clip_distance[0] = clip.x;
    out.clip_distance[1] = clip.y;
    out.clip_distance[2] = clip.z;
    out.clip_distance[3] = clip.w;

    return out;
}

fragment float4 line_segment_fragment(LineFragmentIn in [[stage_in]]) {
    return in.color;
}

struct RingChart {
    float4 fill_color;
    float4 track_color;
    float4 clip_bounds;
    float4 bounds;
    float progress;
    float inner_ratio;
    float start_angle_deg;
    float _pad;
};

struct RingFragmentIn {
    float4 position [[position]];
    float2 pixel_pos;
    float4 fill_color;
    float4 track_color;
    float2 center;
    float outer_radius;
    float inner_radius;
    float progress;
    float start_angle_rad;
};

struct RingVertexOut {
    RingFragmentIn frag;
    float clip_distance [[clip_distance]][4];
};

vertex RingVertexOut ring_chart_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant float2 *unit_vertices [[buffer(0)]],
    constant RingChart *charts [[buffer(1)]],
    constant float2 *viewport_size [[buffer(2)]]
) {
    float2 unit = unit_vertices[vertex_id];
    RingChart c = charts[instance_id];

    float2 pixel_pos = c.bounds.xy + unit * c.bounds.zw;
    float outer = min(c.bounds.z, c.bounds.w) * 0.5;

    RingVertexOut out;
    out.frag.position = to_device_position(pixel_pos, *viewport_size);
    out.frag.pixel_pos = pixel_pos;
    out.frag.fill_color = c.fill_color;
    out.frag.track_color = c.track_color;
    out.frag.center = c.bounds.xy + c.bounds.zw * 0.5;
    out.frag.outer_radius = outer;
    out.frag.inner_radius = outer * clamp(c.inner_ratio, 0.0, 1.0);
    out.frag.progress = clamp(c.progress, 0.0, 1.0);
    out.frag.start_angle_rad = c.start_angle_deg * (M_PI_F / 180.0);

    float4 clip = compute_clip_distance(pixel_pos, c.clip_bounds);
    out.clip_distance[0] = clip.x;
    out.clip_distance[1] = clip.y;
    out.clip_distance[2] = clip.z;
    out.clip_distance[3] = clip.w;

    return out;
}

fragment float4 ring_chart_fragment(RingFragmentIn in [[stage_in]]) {
    float2 d = in.pixel_pos - in.center;
    float dist = length(d);

    float outer = in.outer_radius;
    float inner = in.inner_radius;
    if (dist > outer + 0.5 || dist < inner - 0.5) {
        discard_fragment();
    }

    // Anti-aliased annulus coverage (1px feather both edges).
    float outer_edge = smoothstep(outer + 0.5, outer - 0.5, dist);
    float inner_edge = smoothstep(inner - 0.5, inner + 0.5, dist);
    float band = outer_edge * inner_edge;

    // Angle progress sweep. atan2(dy, dx) in screen-y-down rotates
    // CW from +x. start_angle_rad places progress=0 at the desired
    // start (default -90deg = 12 o'clock).
    float two_pi = 2.0 * M_PI_F;
    float angle = atan2(d.y, d.x) - in.start_angle_rad;
    angle = angle - two_pi * floor(angle / two_pi);
    float t = angle / two_pi;

    float4 col = (t < in.progress) ? in.fill_color : in.track_color;
    col.a *= band;
    return col;
}

// ----------------------------------------------------------------
// Polychrome sprite (RGBA atlas). Used for app icons baked from
// NSImage. The fragment samples the atlas directly; alpha already
// premultiplied by the bake step so the renderer's premultiplied
// blend equation just works.
// ----------------------------------------------------------------

struct ColorSpriteInstance {
    float2 position;
    float2 size;
    float2 uv_origin;
    float2 uv_size;
    float4 clip_bounds;
};

struct ColorSpriteFragmentIn {
    float4 position [[position]];
    float2 uv;
};

struct ColorSpriteVertexOut {
    ColorSpriteFragmentIn frag;
    float clip_distance [[clip_distance]][4];
};

vertex ColorSpriteVertexOut color_sprite_vertex(
    uint vertex_id [[vertex_id]],
    uint instance_id [[instance_id]],
    constant float2 *unit_vertices [[buffer(0)]],
    constant ColorSpriteInstance *sprites [[buffer(1)]],
    constant float2 *viewport_size [[buffer(2)]]
) {
    float2 unit_pos = unit_vertices[vertex_id];
    ColorSpriteInstance s = sprites[instance_id];
    float2 pixel_pos = s.position + unit_pos * s.size;

    ColorSpriteVertexOut out;
    out.frag.position = to_device_position(pixel_pos, *viewport_size);
    out.frag.uv = s.uv_origin + unit_pos * s.uv_size;

    float4 clip = compute_clip_distance(pixel_pos, s.clip_bounds);
    out.clip_distance[0] = clip.x;
    out.clip_distance[1] = clip.y;
    out.clip_distance[2] = clip.z;
    out.clip_distance[3] = clip.w;
    return out;
}

fragment float4 color_sprite_fragment(
    ColorSpriteFragmentIn in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlas_sampler [[sampler(0)]]
) {
    return atlas.sample(atlas_sampler, in.uv);
}

// Fullscreen blit: sample a texture over the whole drawable. Used to
// composite the gaussian-blurred backdrop behind a modal.
struct BlitOut {
    float4 position [[position]];
    float2 uv;
};

vertex BlitOut blit_vertex(uint vid [[vertex_id]]) {
    float2 corners[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0),
    };
    float2 v = corners[vid];
    BlitOut out;
    out.position = float4(v, 0.0, 1.0);
    out.uv = float2((v.x + 1.0) * 0.5, 1.0 - (v.y + 1.0) * 0.5);
    return out;
}

fragment float4 blit_fragment(BlitOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    return tex.sample(s, in.uv);
}

// External-frame primitive: one textured quad per draw sampling a caller-owned
// texture (remote screen / video), positioned in pixel space like the UI quads
// and clipped to the layout rect. One uniform per draw at buffer(1) offset.
struct FrameUniform {
    float4 bounds;      // x, y, w, h in points
    float4 clip_bounds; // x, y, w, h in points
    float opacity;
    float _pad0;
    float _pad1;
    float _pad2;
    // YUV->RGB rows for the NV12 path: rgb[c] = dot(csc[c].xyz, yuv) + csc[c].w.
    float4 csc0;
    float4 csc1;
    float4 csc2;
};

struct FrameFragmentIn {
    float4 position [[position]];
    float2 uv;
    float opacity;
};

// clip_distance is a vertex-only output; it cannot live in the fragment stage_in
// struct, so wrap FrameFragmentIn the way the quad/text shaders do.
struct FrameVertexOut {
    FrameFragmentIn frag;
    float clip_distance [[clip_distance]][4];
};

vertex FrameVertexOut frame_vertex(
    uint vertex_id [[vertex_id]],
    constant float2 *unit_vertices [[buffer(0)]],
    constant FrameUniform *frames [[buffer(1)]],
    constant float2 *viewport_size [[buffer(2)]]
) {
    float2 unit_vertex = unit_vertices[vertex_id];
    FrameUniform frame = frames[0];
    float2 pixel_pos = frame.bounds.xy + unit_vertex * frame.bounds.zw;

    FrameVertexOut out;
    out.frag.position = to_device_position(pixel_pos, *viewport_size);
    out.frag.uv = unit_vertex;
    out.frag.opacity = frame.opacity;

    float4 clip = compute_clip_distance(pixel_pos, frame.clip_bounds);
    out.clip_distance[0] = clip.x;
    out.clip_distance[1] = clip.y;
    out.clip_distance[2] = clip.z;
    out.clip_distance[3] = clip.w;
    return out;
}

fragment float4 frame_fragment(
    FrameFragmentIn in [[stage_in]],
    texture2d<float> frame_tex [[texture(0)]],
    sampler frame_sampler [[sampler(0)]]
) {
    float4 c = frame_tex.sample(frame_sampler, in.uv);
    return float4(c.rgb, c.a * in.opacity);
}

// NV12: luma in plane 0 (R8), chroma in plane 1 (RG8, half res). The bilinear
// sampler upsamples chroma for free. csc carries the colorspace + range.
fragment float4 frame_nv12_fragment(
    FrameFragmentIn in [[stage_in]],
    constant FrameUniform *frames [[buffer(0)]],
    texture2d<float> luma [[texture(0)]],
    texture2d<float> chroma [[texture(1)]],
    sampler frame_sampler [[sampler(0)]]
) {
    FrameUniform f = frames[0];
    float3 yuv = float3(
        luma.sample(frame_sampler, in.uv).r,
        chroma.sample(frame_sampler, in.uv).r,
        chroma.sample(frame_sampler, in.uv).g
    );
    float3 rgb = float3(
        dot(f.csc0.xyz, yuv) + f.csc0.w,
        dot(f.csc1.xyz, yuv) + f.csc1.w,
        dot(f.csc2.xyz, yuv) + f.csc2.w
    );
    return float4(saturate(rgb), in.opacity);
}
