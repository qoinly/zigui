// GLSL port of the ring-chart vertex stage: a full quad over the bounds; the
// fragment stage draws the SDF annulus + arc sweep. Same y-down NDC note as
// quad.vert. 80-byte RingChart instance layout.
#version 450

const vec2 UNIT[6] = vec2[](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));

const float PI = 3.14159265358979;

layout(push_constant) uniform Viewport {
    vec2 viewport_size;
} pc;

struct RingChart {
    vec4 fill_color;
    vec4 track_color;
    vec4 clip_bounds;
    vec4 bounds;
    float progress;
    float inner_ratio;
    float start_angle_deg;
    float pad;
};

layout(set = 0, binding = 0, std430) readonly buffer Rings {
    RingChart rings[];
};

layout(location = 0) out vec2 v_pixel_pos;
layout(location = 1) out vec4 v_fill_color;
layout(location = 2) out vec4 v_track_color;
layout(location = 3) out vec2 v_center;
layout(location = 4) out float v_outer_radius;
layout(location = 5) out float v_inner_radius;
layout(location = 6) out float v_progress;
layout(location = 7) out float v_start_angle_rad;

out gl_PerVertex {
    vec4 gl_Position;
    float gl_ClipDistance[4];
};

void main() {
    vec2 unit = UNIT[gl_VertexIndex];
    RingChart c = rings[gl_InstanceIndex];

    vec2 pixel_pos = c.bounds.xy + unit * c.bounds.zw;
    float outer = min(c.bounds.z, c.bounds.w) * 0.5;

    vec2 ndc = (pixel_pos / pc.viewport_size) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);

    gl_ClipDistance[0] = pixel_pos.x - c.clip_bounds.x;
    gl_ClipDistance[1] = c.clip_bounds.x + c.clip_bounds.z - pixel_pos.x;
    gl_ClipDistance[2] = pixel_pos.y - c.clip_bounds.y;
    gl_ClipDistance[3] = c.clip_bounds.y + c.clip_bounds.w - pixel_pos.y;

    v_pixel_pos = pixel_pos;
    v_fill_color = c.fill_color;
    v_track_color = c.track_color;
    v_center = c.bounds.xy + c.bounds.zw * 0.5;
    v_outer_radius = outer;
    v_inner_radius = outer * clamp(c.inner_ratio, 0.0, 1.0);
    v_progress = clamp(c.progress, 0.0, 1.0);
    v_start_angle_rad = c.start_angle_deg * (PI / 180.0);
}
