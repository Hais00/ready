// SPDX-License-Identifier: GPL-3.0-only
#version 450
layout(location=0) out vec2 uv;
layout(constant_id=0) const bool clipYInverted=false;
void main() {
    vec2 p[3] = vec2[](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
    // Normalize Vulkan devices which cannot provide a negative-height viewport.
    vec2 point = p[gl_VertexIndex];
    gl_Position = vec4(point, 0, 1);
    if(clipYInverted) gl_Position.y = -gl_Position.y;
    uv = vec2((point.x+1)*0.5, 1-(point.y+1)*0.5);
}
