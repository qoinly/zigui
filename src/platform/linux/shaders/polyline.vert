// GLSL port of the polyline (filled area) vertex stage: each instance is one
// chart segment extruded down to the baseline, with an optional alpha fade.
// Same y-down NDC note as quad.vert. 64-byte Polyline instance layout.
#version 450

const vec2 UNIT[6] = vec2[](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));

layout(push_constant) uniform Viewport {
    vec2 viewport_size;
    vec2 rot;
} pc;

struct Polyline {
    vec2 pos_a;
    vec2 pos_b;
    vec4 fill_color;
    vec4 clip_bounds;
    float baseline_y;
    float gradient;
    vec2 pad;
};

layout(set = 0, binding = 0, std430) readonly buffer Polylines {
    Polyline segs[];
};

layout(location = 0) out vec4 v_color;

out gl_PerVertex {
    vec4 gl_Position;
    float gl_ClipDistance[4];
};

void main() {
    vec2 unit_pos = UNIT[gl_VertexIndex];
    Polyline seg = segs[gl_InstanceIndex];

    vec2 top = mix(seg.pos_a, seg.pos_b, unit_pos.x);
    vec2 bottom = vec2(top.x, seg.baseline_y);
    vec2 pixel_pos = mix(top, bottom, unit_pos.y);

    vec2 ndc = (pixel_pos / pc.viewport_size) * 2.0 - 1.0;
    ndc = vec2(ndc.x * pc.rot.x - ndc.y * pc.rot.y,
               ndc.x * pc.rot.y + ndc.y * pc.rot.x);
    gl_Position = vec4(ndc, 0.0, 1.0);

    gl_ClipDistance[0] = pixel_pos.x - seg.clip_bounds.x;
    gl_ClipDistance[1] = seg.clip_bounds.x + seg.clip_bounds.z - pixel_pos.x;
    gl_ClipDistance[2] = pixel_pos.y - seg.clip_bounds.y;
    gl_ClipDistance[3] = seg.clip_bounds.y + seg.clip_bounds.w - pixel_pos.y;

    float fade = mix(1.0, 1.0 - seg.gradient, unit_pos.y);
    v_color = vec4(seg.fill_color.rgb, seg.fill_color.a * fade);
}
