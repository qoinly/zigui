// GLSL port of the quad vertex stage (see shaders.hlsl). Instance data comes
// from a storage buffer indexed by gl_InstanceIndex; the unit square from a
// const array indexed by gl_VertexIndex. Vulkan NDC is y-DOWN over a top-left
// framebuffer, so the Metal/HLSL `ndc.y = -ndc.y` flip must NOT be ported -
// top-left pixel coordinates map to NDC directly.
#version 450

const vec2 UNIT[6] = vec2[](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));

layout(push_constant) uniform Viewport {
    vec2 viewport_size;
} pc;

struct Quad {
    vec4 bounds;
    vec4 background;
    vec4 corner_radii;
    vec4 border_color;
    vec4 border_widths;
    vec4 transform;
    vec4 clip_bounds;
};

layout(set = 0, binding = 0, std430) readonly buffer Quads {
    Quad quads[];
};

layout(location = 0) out vec4 v_background;
layout(location = 1) out vec4 v_border_color;
layout(location = 2) out vec2 v_quad_pos;
layout(location = 3) out vec4 v_corner_radii;
layout(location = 4) out vec4 v_border_widths;
layout(location = 5) out vec2 v_quad_size;

out gl_PerVertex {
    vec4 gl_Position;
    float gl_ClipDistance[4];
};

void main() {
    vec2 unit_vertex = UNIT[gl_VertexIndex];
    Quad q = quads[gl_InstanceIndex];

    float rotation = q.transform.x;
    vec2 scale = q.transform.yz;

    vec2 center = q.bounds.xy + q.bounds.zw * 0.5;
    vec2 centered = (unit_vertex - 0.5) * scale;

    float cos_r = cos(rotation);
    float sin_r = sin(rotation);
    vec2 rotated = vec2(
        centered.x * cos_r - centered.y * sin_r,
        centered.x * sin_r + centered.y * cos_r);

    vec2 pixel_pos = center + rotated * q.bounds.zw;

    vec2 ndc = (pixel_pos / pc.viewport_size) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);

    gl_ClipDistance[0] = pixel_pos.x - q.clip_bounds.x;
    gl_ClipDistance[1] = q.clip_bounds.x + q.clip_bounds.z - pixel_pos.x;
    gl_ClipDistance[2] = pixel_pos.y - q.clip_bounds.y;
    gl_ClipDistance[3] = q.clip_bounds.y + q.clip_bounds.w - pixel_pos.y;

    v_background = q.background;
    v_border_color = q.border_color;
    v_quad_pos = unit_vertex;
    v_corner_radii = q.corner_radii;
    v_border_widths = q.border_widths;
    v_quad_size = q.bounds.zw;
}
