// Color sprite fragment: the RGBA atlas carries the pixels as-is.
#version 450

layout(set = 0, binding = 1) uniform sampler2D color_atlas;

layout(location = 0) in vec2 v_uv;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(color_atlas, v_uv);
}
