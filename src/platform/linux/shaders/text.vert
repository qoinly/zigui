// GLSL port of the text (monochrome sprite) vertex stage; same y-down NDC
// note as quad.vert. Instance layout matches the 64-byte MonochromeSprite.
#version 450

const vec2 UNIT[6] = vec2[](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));

layout(push_constant) uniform Viewport {
    vec2 viewport_size;
    vec2 rot;
} pc;

struct GlyphInstance {
    vec2 position;
    vec2 size;
    vec2 uv_origin;
    vec2 uv_size;
    vec4 color;
    vec4 clip_bounds;
};

layout(set = 0, binding = 0, std430) readonly buffer Glyphs {
    GlyphInstance glyphs[];
};

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_color;

out gl_PerVertex {
    vec4 gl_Position;
    float gl_ClipDistance[4];
};

void main() {
    vec2 unit_pos = UNIT[gl_VertexIndex];
    GlyphInstance g = glyphs[gl_InstanceIndex];
    vec2 pixel_pos = g.position + unit_pos * g.size;

    vec2 ndc = (pixel_pos / pc.viewport_size) * 2.0 - 1.0;
    ndc = vec2(ndc.x * pc.rot.x - ndc.y * pc.rot.y,
               ndc.x * pc.rot.y + ndc.y * pc.rot.x);
    gl_Position = vec4(ndc, 0.0, 1.0);

    gl_ClipDistance[0] = pixel_pos.x - g.clip_bounds.x;
    gl_ClipDistance[1] = g.clip_bounds.x + g.clip_bounds.z - pixel_pos.x;
    gl_ClipDistance[2] = pixel_pos.y - g.clip_bounds.y;
    gl_ClipDistance[3] = g.clip_bounds.y + g.clip_bounds.w - pixel_pos.y;

    v_uv = g.uv_origin + unit_pos * g.uv_size;
    v_color = g.color;
}
