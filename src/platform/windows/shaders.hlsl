// HLSL port of shaders.metal for the Direct3D 11 backend. Instance data is read
// from a StructuredBuffer indexed by SV_InstanceID; the unit square comes from a
// static array indexed by SV_VertexID (no input layout). Clip rects ride on
// SV_ClipDistance0 (four planes). Coordinates are pixel-space, top-left origin;
// the y flip in to_device_position is identical to Metal (both have y-up NDC
// over a top-left framebuffer).

static const float2 UNIT[6] = {
    float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
    float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0),
};

static const float PI = 3.14159265358979323846;

cbuffer Viewport : register(b0) {
    float2 viewport_size;
    float2 viewport_pad;
};

float4 to_device_position(float2 pixel_pos) {
    float2 ndc = (pixel_pos / viewport_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    return float4(ndc, 0.0, 1.0);
}

float4 compute_clip_distance(float2 pixel_pos, float4 clip_bounds) {
    return float4(
        pixel_pos.x - clip_bounds.x,
        clip_bounds.x + clip_bounds.z - pixel_pos.x,
        pixel_pos.y - clip_bounds.y,
        clip_bounds.y + clip_bounds.w - pixel_pos.y);
}

float rounded_rect_sdf(float2 pos, float2 half_size, float radius) {
    float2 d = abs(pos) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float pick_corner_radius(float2 pos, float4 corner_radii) {
    if (pos.x < 0.5) {
        return pos.y < 0.5 ? corner_radii.x : corner_radii.z;
    }
    return pos.y < 0.5 ? corner_radii.y : corner_radii.w;
}

float pick_border_width(float2 center_pos, float4 widths) {
    if (abs(center_pos.y) > abs(center_pos.x)) {
        return center_pos.y < 0.0 ? widths.x : widths.z;
    }
    return center_pos.x > 0.0 ? widths.y : widths.w;
}

// ---- Quad ------------------------------------------------------------------

struct Quad {
    float4 bounds;
    float4 background;
    float4 corner_radii;
    float4 border_color;
    float4 border_widths;
    float4 transform;
    float4 clip_bounds;
};

StructuredBuffer<Quad> quads : register(t0);

struct QuadOut {
    float4 position : SV_Position;
    float4 background : COLOR0;
    float4 border_color : COLOR1;
    float2 quad_pos : TEXCOORD0;
    float4 corner_radii : TEXCOORD1;
    float4 border_widths : TEXCOORD2;
    float2 quad_size : TEXCOORD3;
    float4 clip : SV_ClipDistance0;
};

QuadOut quad_vertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float2 unit_vertex = UNIT[vid];
    Quad q = quads[iid];

    float rotation = q.transform.x;
    float scale_x = q.transform.y;
    float scale_y = q.transform.z;

    float2 center = q.bounds.xy + q.bounds.zw * 0.5;
    float2 centered = (unit_vertex - 0.5) * float2(scale_x, scale_y);

    float cos_r = cos(rotation);
    float sin_r = sin(rotation);
    float2 rotated = float2(
        centered.x * cos_r - centered.y * sin_r,
        centered.x * sin_r + centered.y * cos_r);

    float2 pixel_pos = center + rotated * q.bounds.zw;

    QuadOut o;
    o.position = to_device_position(pixel_pos);
    o.background = q.background;
    o.border_color = q.border_color;
    o.quad_pos = unit_vertex;
    o.corner_radii = q.corner_radii;
    o.border_widths = q.border_widths;
    o.quad_size = q.bounds.zw;
    o.clip = compute_clip_distance(pixel_pos, q.clip_bounds);
    return o;
}

float4 quad_fragment(QuadOut input) : SV_Target {
    float2 half_size = input.quad_size * 0.5;
    float2 center_pos = (input.quad_pos - 0.5) * input.quad_size;

    float radius = pick_corner_radius(input.quad_pos, input.corner_radii);
    float border_width = pick_border_width(center_pos, input.border_widths);

    float outer_dist = rounded_rect_sdf(center_pos, half_size, radius);

    float inner_radius = max(0.0, radius - border_width);
    float2 inner_half_size = max(float2(0.0, 0.0), half_size - border_width);
    float inner_dist = rounded_rect_sdf(center_pos, inner_half_size, inner_radius);

    float outer_alpha = 1.0 - smoothstep(-0.5, 0.5, outer_dist);

    float border_sum = input.border_widths.x + input.border_widths.y +
        input.border_widths.z + input.border_widths.w;
    if (border_sum <= 0.0) {
        return float4(input.background.rgb, input.background.a * outer_alpha);
    }

    float border_blend = smoothstep(-0.5, 0.5, inner_dist);
    float4 bg = input.background * (1.0 - border_blend);
    float4 border = input.border_color * border_blend;
    float4 color = bg + border;
    return float4(color.rgb, color.a * outer_alpha);
}

// ---- Text (monochrome sprite) ---------------------------------------------

struct GlyphInstance {
    float2 position;
    float2 size;
    float2 uv_origin;
    float2 uv_size;
    float4 color;
    float4 clip_bounds;
};

StructuredBuffer<GlyphInstance> glyphs : register(t0);
Texture2D mono_atlas : register(t0);
SamplerState atlas_sampler : register(s0);

struct TextOut {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
    float4 clip : SV_ClipDistance0;
};

TextOut text_vertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float2 unit_pos = UNIT[vid];
    GlyphInstance g = glyphs[iid];
    float2 pixel_pos = g.position + unit_pos * g.size;

    TextOut o;
    o.position = to_device_position(pixel_pos);
    o.uv = g.uv_origin + unit_pos * g.uv_size;
    o.color = g.color;
    o.clip = compute_clip_distance(pixel_pos, g.clip_bounds);
    return o;
}

float4 text_fragment(TextOut input) : SV_Target {
    float alpha = mono_atlas.Sample(atlas_sampler, input.uv).r;
    return float4(input.color.rgb, input.color.a * alpha);
}

// ---- Color sprite (RGBA atlas) --------------------------------------------

struct ColorSpriteInstance {
    float2 position;
    float2 size;
    float2 uv_origin;
    float2 uv_size;
    float4 clip_bounds;
};

StructuredBuffer<ColorSpriteInstance> color_sprites : register(t0);
Texture2D color_atlas : register(t0);

struct ColorSpriteOut {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float4 clip : SV_ClipDistance0;
};

ColorSpriteOut color_sprite_vertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float2 unit_pos = UNIT[vid];
    ColorSpriteInstance s = color_sprites[iid];
    float2 pixel_pos = s.position + unit_pos * s.size;

    ColorSpriteOut o;
    o.position = to_device_position(pixel_pos);
    o.uv = s.uv_origin + unit_pos * s.uv_size;
    o.clip = compute_clip_distance(pixel_pos, s.clip_bounds);
    return o;
}

float4 color_sprite_fragment(ColorSpriteOut input) : SV_Target {
    return color_atlas.Sample(atlas_sampler, input.uv);
}

// ---- Polyline (filled area) -----------------------------------------------

struct Polyline {
    float2 pos_a;
    float2 pos_b;
    float4 fill_color;
    float4 clip_bounds;
    float baseline_y;
    float gradient;
    float pad1;
    float pad2;
};

StructuredBuffer<Polyline> polylines : register(t0);

struct PolylineOut {
    float4 position : SV_Position;
    float4 fill_color : COLOR0;
    float4 clip : SV_ClipDistance0;
};

PolylineOut polyline_vertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float2 unit_pos = UNIT[vid];
    Polyline seg = polylines[iid];

    float2 top = lerp(seg.pos_a, seg.pos_b, unit_pos.x);
    float2 bottom = float2(top.x, seg.baseline_y);
    float2 pixel_pos = lerp(top, bottom, unit_pos.y);

    PolylineOut o;
    o.position = to_device_position(pixel_pos);
    float fade = lerp(1.0, 1.0 - seg.gradient, unit_pos.y);
    o.fill_color = float4(seg.fill_color.rgb, seg.fill_color.a * fade);
    o.clip = compute_clip_distance(pixel_pos, seg.clip_bounds);
    return o;
}

float4 polyline_fragment(PolylineOut input) : SV_Target {
    return input.fill_color;
}

// ---- Line segment ----------------------------------------------------------

struct LineSegment {
    float2 pos_a;
    float2 pos_b;
    float4 color;
    float4 clip_bounds;
    float thickness;
    float pad0;
    float pad1;
    float pad2;
};

StructuredBuffer<LineSegment> lines : register(t0);

struct LineOut {
    float4 position : SV_Position;
    float4 color : COLOR0;
    float4 clip : SV_ClipDistance0;
};

LineOut line_segment_vertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float2 unit_pos = UNIT[vid];
    LineSegment seg = lines[iid];

    float2 dir = seg.pos_b - seg.pos_a;
    float len = length(dir);
    float2 norm_dir = len > 0.0 ? dir / len : float2(1.0, 0.0);
    float2 perp = float2(-norm_dir.y, norm_dir.x);
    float half_thick = seg.thickness * 0.5;

    float2 along = lerp(seg.pos_a, seg.pos_b, unit_pos.x);
    float side = unit_pos.y * 2.0 - 1.0;
    float2 pixel_pos = along + perp * side * half_thick;

    LineOut o;
    o.position = to_device_position(pixel_pos);
    o.color = seg.color;
    o.clip = compute_clip_distance(pixel_pos, seg.clip_bounds);
    return o;
}

float4 line_segment_fragment(LineOut input) : SV_Target {
    return input.color;
}

// ---- Ring chart ------------------------------------------------------------

struct RingChart {
    float4 fill_color;
    float4 track_color;
    float4 clip_bounds;
    float4 bounds;
    float progress;
    float inner_ratio;
    float start_angle_deg;
    float pad;
};

StructuredBuffer<RingChart> rings : register(t0);

struct RingOut {
    float4 position : SV_Position;
    float2 pixel_pos : TEXCOORD0;
    float4 fill_color : COLOR0;
    float4 track_color : COLOR1;
    float2 center : TEXCOORD1;
    float outer_radius : TEXCOORD2;
    float inner_radius : TEXCOORD3;
    float progress : TEXCOORD4;
    float start_angle_rad : TEXCOORD5;
    float4 clip : SV_ClipDistance0;
};

RingOut ring_chart_vertex(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    float2 unit = UNIT[vid];
    RingChart c = rings[iid];

    float2 pixel_pos = c.bounds.xy + unit * c.bounds.zw;
    float outer = min(c.bounds.z, c.bounds.w) * 0.5;

    RingOut o;
    o.position = to_device_position(pixel_pos);
    o.pixel_pos = pixel_pos;
    o.fill_color = c.fill_color;
    o.track_color = c.track_color;
    o.center = c.bounds.xy + c.bounds.zw * 0.5;
    o.outer_radius = outer;
    o.inner_radius = outer * clamp(c.inner_ratio, 0.0, 1.0);
    o.progress = clamp(c.progress, 0.0, 1.0);
    o.start_angle_rad = c.start_angle_deg * (PI / 180.0);
    o.clip = compute_clip_distance(pixel_pos, c.clip_bounds);
    return o;
}

float4 ring_chart_fragment(RingOut input) : SV_Target {
    float2 d = input.pixel_pos - input.center;
    float dist = length(d);

    float outer = input.outer_radius;
    float inner = input.inner_radius;
    if (dist > outer + 0.5 || dist < inner - 0.5) {
        discard;
    }

    float outer_edge = smoothstep(outer + 0.5, outer - 0.5, dist);
    float inner_edge = smoothstep(inner - 0.5, inner + 0.5, dist);
    float band = outer_edge * inner_edge;

    float two_pi = 2.0 * PI;
    float angle = atan2(d.y, d.x) - input.start_angle_rad;
    angle = angle - two_pi * floor(angle / two_pi);
    float t = angle / two_pi;

    float4 col = (t < input.progress) ? input.fill_color : input.track_color;
    col.a *= band;
    return col;
}

// ---- External frame --------------------------------------------------------

cbuffer FrameParams : register(b1) {
    float4 frame_bounds;
    float4 frame_clip_bounds;
    float frame_opacity;
    float3 frame_pad;
    float4 frame_csc0;
    float4 frame_csc1;
    float4 frame_csc2;
};

Texture2D frame_tex : register(t0);
Texture2D frame_chroma_tex : register(t1);

struct FrameOut {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float opacity : TEXCOORD1;
    float4 clip : SV_ClipDistance0;
};

FrameOut frame_vertex(uint vid : SV_VertexID) {
    float2 unit_vertex = UNIT[vid];
    float2 pixel_pos = frame_bounds.xy + unit_vertex * frame_bounds.zw;

    FrameOut o;
    o.position = to_device_position(pixel_pos);
    o.uv = unit_vertex;
    o.opacity = frame_opacity;
    o.clip = compute_clip_distance(pixel_pos, frame_clip_bounds);
    return o;
}

float4 frame_fragment(FrameOut input) : SV_Target {
    float4 c = frame_tex.Sample(atlas_sampler, input.uv);
    return float4(c.rgb, c.a * input.opacity);
}

float4 frame_nv12_fragment(FrameOut input) : SV_Target {
    float y = frame_tex.Sample(atlas_sampler, input.uv).r;
    float2 cbcr = frame_chroma_tex.Sample(atlas_sampler, input.uv).rg;
    float3 yuv = float3(y, cbcr.x, cbcr.y);
    float3 rgb = float3(
        dot(frame_csc0.xyz, yuv) + frame_csc0.w,
        dot(frame_csc1.xyz, yuv) + frame_csc1.w,
        dot(frame_csc2.xyz, yuv) + frame_csc2.w);
    return float4(saturate(rgb), input.opacity);
}

// ---- Fullscreen blit (modal backdrop composite) ---------------------------

Texture2D blit_tex : register(t0);

struct BlitOut {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

BlitOut blit_vertex(uint vid : SV_VertexID) {
    float2 corners[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0),
    };
    float2 v = corners[vid];
    BlitOut o;
    o.position = float4(v, 0.0, 1.0);
    o.uv = float2((v.x + 1.0) * 0.5, 1.0 - (v.y + 1.0) * 0.5);
    return o;
}

float4 blit_fragment(BlitOut input) : SV_Target {
    return blit_tex.Sample(atlas_sampler, input.uv);
}

// Separable Gaussian (the MPSImageGaussianBlur stand-in): one pass per axis,
// pinned to a static radius so the loop unrolls. texel is 1/size in pixels;
// sigma rides in the same constant so the weight falloff tracks the DPI scale.
cbuffer BlurParams : register(b1) {
    float2 blur_texel;
    float blur_sigma;
    float blur_pad;
};

static const int BLUR_RADIUS = 24;

float4 blur_axis(float2 uv, float2 axis) {
    float two_sigma_sq = 2.0 * blur_sigma * blur_sigma;
    float4 sum = float4(0.0, 0.0, 0.0, 0.0);
    float weight_sum = 0.0;
    [unroll]
    for (int i = -BLUR_RADIUS; i <= BLUR_RADIUS; i++) {
        float w = exp(-float(i * i) / two_sigma_sq);
        sum += blit_tex.Sample(atlas_sampler, uv + axis * blur_texel * float(i)) * w;
        weight_sum += w;
    }
    return sum / weight_sum;
}

float4 blur_h_fragment(BlitOut input) : SV_Target {
    return blur_axis(input.uv, float2(1.0, 0.0));
}

float4 blur_v_fragment(BlitOut input) : SV_Target {
    return blur_axis(input.uv, float2(0.0, 1.0));
}
