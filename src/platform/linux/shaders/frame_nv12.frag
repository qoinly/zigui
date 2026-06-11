// NV12 frame fragment (the HLSL frame_nv12_fragment): sample the R8 luma and
// half-size RG8 chroma planes, then apply the CPU-baked YUV->RGB rows from the
// push constants (see frame.csc_rows).
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
layout(set = 0, binding = 1) uniform sampler2D frame_chroma_tex;

layout(location = 0) in vec2 v_uv;

layout(location = 0) out vec4 out_color;

void main() {
    float y = texture(frame_tex, v_uv).r;
    vec2 cbcr = texture(frame_chroma_tex, v_uv).rg;
    vec3 yuv = vec3(y, cbcr.x, cbcr.y);
    vec3 rgb = vec3(
        dot(pc.csc0.xyz, yuv) + pc.csc0.w,
        dot(pc.csc1.xyz, yuv) + pc.csc1.w,
        dot(pc.csc2.xyz, yuv) + pc.csc2.w);
    out_color = vec4(clamp(rgb, 0.0, 1.0), pc.opacity_pad.x);
}
