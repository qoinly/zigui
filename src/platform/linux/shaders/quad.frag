// GLSL port of the quad fragment stage (see shaders.hlsl): SDF rounded rect
// with per-corner radii and per-edge border widths, straight-alpha output.
#version 450

layout(location = 0) in vec4 v_background;
layout(location = 1) in vec4 v_border_color;
layout(location = 2) in vec2 v_quad_pos;
layout(location = 3) in vec4 v_corner_radii;
layout(location = 4) in vec4 v_border_widths;
layout(location = 5) in vec2 v_quad_size;
layout(location = 6) in vec2 v_border_dash;

layout(location = 0) out vec4 out_color;

float rounded_rect_sdf(vec2 pos, vec2 half_size, float radius) {
    vec2 d = abs(pos) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float pick_corner_radius(vec2 pos, vec4 corner_radii) {
    if (pos.x < 0.5) {
        return pos.y < 0.5 ? corner_radii.x : corner_radii.z;
    }
    return pos.y < 0.5 ? corner_radii.y : corner_radii.w;
}

float pick_border_width(vec2 center_pos, vec4 widths) {
    if (abs(center_pos.y) > abs(center_pos.x)) {
        return center_pos.y < 0.0 ? widths.x : widths.z;
    }
    return center_pos.x > 0.0 ? widths.y : widths.w;
}

void main() {
    vec2 half_size = v_quad_size * 0.5;
    vec2 center_pos = (v_quad_pos - 0.5) * v_quad_size;

    float radius = pick_corner_radius(v_quad_pos, v_corner_radii);
    float border_width = pick_border_width(center_pos, v_border_widths);

    float outer_dist = rounded_rect_sdf(center_pos, half_size, radius);

    float inner_radius = max(0.0, radius - border_width);
    vec2 inner_half_size = max(vec2(0.0), half_size - border_width);
    float inner_dist = rounded_rect_sdf(center_pos, inner_half_size, inner_radius);

    float outer_alpha = 1.0 - smoothstep(-0.5, 0.5, outer_dist);

    float border_sum = v_border_widths.x + v_border_widths.y +
        v_border_widths.z + v_border_widths.w;
    if (border_sum <= 0.0) {
        out_color = vec4(v_background.rgb, v_background.a * outer_alpha);
        return;
    }

    float border_blend = smoothstep(-0.5, 0.5, inner_dist);

    // Dashed border: drop the border in the dash gaps, walking the coordinate
    // along whichever edge this fragment sits on.
    if (v_border_dash.x > 0.0) {
        float along = (abs(center_pos.y) > abs(center_pos.x)) ? center_pos.x : center_pos.y;
        float period = v_border_dash.x + v_border_dash.y;
        float duty = v_border_dash.x / period;
        float dc = fract(along / period);
        float aa = max(fwidth(along) / period, 0.001);
        border_blend *= 1.0 - smoothstep(duty - aa, duty + aa, dc);
    }

    vec4 bg = v_background * (1.0 - border_blend);
    vec4 border = v_border_color * border_blend;
    vec4 color = bg + border;
    out_color = vec4(color.rgb, color.a * outer_alpha);
}
