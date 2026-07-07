// GLSL port of the HLSL frame vertex stage: one non-instanced quad per draw,
// parameters in push constants instead of a cbuffer (112 bytes fits the 128-byte
// Vulkan minimum, so no per-frame buffer traffic). Same y-down NDC rule as
// quad.vert: no y flip.
#version 450

const vec2 UNIT[6] = vec2[](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));

layout(push_constant) uniform FrameParams {
    vec2 viewport_size;
    vec2 rot;
    vec4 bounds;
    vec4 clip_bounds;
    vec4 opacity_pad;
    vec4 csc0;
    vec4 csc1;
    vec4 csc2;
} pc;

layout(location = 0) out vec2 v_uv;

out gl_PerVertex {
    vec4 gl_Position;
    float gl_ClipDistance[4];
};

void main() {
    vec2 unit_vertex = UNIT[gl_VertexIndex];
    vec2 pixel_pos = pc.bounds.xy + unit_vertex * pc.bounds.zw;

    vec2 ndc = (pixel_pos / pc.viewport_size) * 2.0 - 1.0;
    ndc = vec2(ndc.x * pc.rot.x - ndc.y * pc.rot.y,
               ndc.x * pc.rot.y + ndc.y * pc.rot.x);
    gl_Position = vec4(ndc, 0.0, 1.0);

    gl_ClipDistance[0] = pixel_pos.x - pc.clip_bounds.x;
    gl_ClipDistance[1] = pc.clip_bounds.x + pc.clip_bounds.z - pixel_pos.x;
    gl_ClipDistance[2] = pixel_pos.y - pc.clip_bounds.y;
    gl_ClipDistance[3] = pc.clip_bounds.y + pc.clip_bounds.w - pixel_pos.y;

    v_uv = unit_vertex;
}
