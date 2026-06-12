// Dmabuf NV12 frame fragment: the multiplanar image is sampled through an
// immutable ycbcr-conversion sampler, so the YUV->RGB happens in the sampler
// and the texel arrives as RGB - the push-constant CSC rows go unused (they
// stay in the block so all frame pipelines share one push layout).
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
    vec3 rgb = texture(frame_tex, v_uv).rgb;
    out_color = vec4(rgb, pc.opacity_pad.x);
}
