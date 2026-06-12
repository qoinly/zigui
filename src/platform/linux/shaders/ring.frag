// Ring-chart fragment (the HLSL ring_chart_fragment): SDF annulus band with a
// progress arc swept clockwise from start_angle.
#version 450

const float PI = 3.14159265358979;

layout(location = 0) in vec2 v_pixel_pos;
layout(location = 1) in vec4 v_fill_color;
layout(location = 2) in vec4 v_track_color;
layout(location = 3) in vec2 v_center;
layout(location = 4) in float v_outer_radius;
layout(location = 5) in float v_inner_radius;
layout(location = 6) in float v_progress;
layout(location = 7) in float v_start_angle_rad;

layout(location = 0) out vec4 out_color;

void main() {
    vec2 d = v_pixel_pos - v_center;
    float dist = length(d);

    float outer = v_outer_radius;
    float inner = v_inner_radius;
    if (dist > outer + 0.5 || dist < inner - 0.5) {
        discard;
    }

    float outer_edge = smoothstep(outer + 0.5, outer - 0.5, dist);
    float inner_edge = smoothstep(inner - 0.5, inner + 0.5, dist);
    float band = outer_edge * inner_edge;

    float two_pi = 2.0 * PI;
    float angle = atan(d.y, d.x) - v_start_angle_rad;
    angle = angle - two_pi * floor(angle / two_pi);
    float t = angle / two_pi;

    vec4 col = (t < v_progress) ? v_fill_color : v_track_color;
    col.a *= band;
    out_color = col;
}
