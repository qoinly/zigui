// GLSL port of the line-segment vertex stage: the unit square is stretched
// along pos_a->pos_b and widened perpendicular by thickness. Same y-down NDC
// note as quad.vert. 64-byte LineSegment instance layout.
#version 450

const vec2 UNIT[6] = vec2[](
    vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
    vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0));

layout(push_constant) uniform Viewport {
    vec2 viewport_size;
    vec2 rot;
} pc;

struct LineSegment {
    vec2 pos_a;
    vec2 pos_b;
    vec4 color;
    vec4 clip_bounds;
    float thickness;
    float pad0;
    vec2 pad1;
};

layout(set = 0, binding = 0, std430) readonly buffer Lines {
    LineSegment segs[];
};

layout(location = 0) out vec4 v_color;

out gl_PerVertex {
    vec4 gl_Position;
    float gl_ClipDistance[4];
};

void main() {
    vec2 unit_pos = UNIT[gl_VertexIndex];
    LineSegment seg = segs[gl_InstanceIndex];

    vec2 dir = seg.pos_b - seg.pos_a;
    float len = length(dir);
    vec2 norm_dir = len > 0.0 ? dir / len : vec2(1.0, 0.0);
    vec2 perp = vec2(-norm_dir.y, norm_dir.x);
    float half_thick = seg.thickness * 0.5;

    vec2 along = mix(seg.pos_a, seg.pos_b, unit_pos.x);
    float side = unit_pos.y * 2.0 - 1.0;
    vec2 pixel_pos = along + perp * side * half_thick;

    vec2 ndc = (pixel_pos / pc.viewport_size) * 2.0 - 1.0;
    ndc = vec2(ndc.x * pc.rot.x - ndc.y * pc.rot.y,
               ndc.x * pc.rot.y + ndc.y * pc.rot.x);
    gl_Position = vec4(ndc, 0.0, 1.0);

    gl_ClipDistance[0] = pixel_pos.x - seg.clip_bounds.x;
    gl_ClipDistance[1] = seg.clip_bounds.x + seg.clip_bounds.z - pixel_pos.x;
    gl_ClipDistance[2] = pixel_pos.y - seg.clip_bounds.y;
    gl_ClipDistance[3] = seg.clip_bounds.y + seg.clip_bounds.w - pixel_pos.y;

    v_color = seg.color;
}
