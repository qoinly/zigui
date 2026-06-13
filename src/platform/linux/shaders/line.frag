// Line-segment fragment: flat color resolved in the vertex stage.
#version 450

layout(location = 0) in vec4 v_color;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = v_color;
}
