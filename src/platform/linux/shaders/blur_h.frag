// Separable Gaussian, horizontal pass (see shaders.hlsl blur_axis): static
// radius so the loop unrolls; texel is 1/size in pixels, sigma in pixels.
#version 450

layout(push_constant) uniform BlurParams {
    vec2 texel;
    float sigma;
    float pad;
} pc;

layout(set = 0, binding = 0) uniform sampler2D blit_tex;

layout(location = 0) in vec2 v_uv;

layout(location = 0) out vec4 out_color;

const int BLUR_RADIUS = 24;

void main() {
    float two_sigma_sq = 2.0 * pc.sigma * pc.sigma;
    vec4 sum = vec4(0.0);
    float weight_sum = 0.0;
    for (int i = -BLUR_RADIUS; i <= BLUR_RADIUS; i++) {
        float w = exp(-float(i * i) / two_sigma_sq);
        sum += texture(blit_tex, v_uv + vec2(1.0, 0.0) * pc.texel * float(i)) * w;
        weight_sum += w;
    }
    out_color = sum / weight_sum;
}
