// RGBA frame fragment (the HLSL frame_fragment): plain textured quad with the
// frame's opacity. Both frame fragments share frame.vert and its push range.
#version 450

layout(push_constant) uniform FrameParams {
    vec2 viewport_size;
    vec2 pad0;
    vec4 bounds;
    vec4 clip_bounds;
    vec4 opacity_pad;
    vec4 csc0;
    vec4 csc1;
    vec4 csc2;
} pc;

layout(set = 0, binding = 0) uniform sampler2D frame_tex;

layout(location = 0) in vec2 v_uv;

layout(location = 0) out vec4 out_color;

void main() {
    vec4 c = texture(frame_tex, v_uv);
    out_color = vec4(c.rgb, c.a * pc.opacity_pad.x);
}
