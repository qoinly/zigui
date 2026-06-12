// Fullscreen pass vertex (the HLSL blit_vertex): NDC corners straight through.
// Vulkan NDC is y-down, so (-1,-1) IS the top-left and uv needs no flip,
// unlike the HLSL original.
#version 450

const vec2 CORNERS[6] = vec2[](
    vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0),
    vec2(-1.0, 1.0), vec2(1.0, -1.0), vec2(1.0, 1.0));

layout(location = 0) out vec2 v_uv;

void main() {
    vec2 v = CORNERS[gl_VertexIndex];
    gl_Position = vec4(v, 0.0, 1.0);
    v_uv = vec2((v.x + 1.0) * 0.5, (v.y + 1.0) * 0.5);
}
