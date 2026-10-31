// SPDX-License-Identifier: GPL-3.0-only
#version 450
layout(set=0,binding=0) uniform texture2D image;
layout(set=0,binding=1) uniform sampler imageSampler;
layout(set=0,binding=2) uniform Motion { vec4 motion; };
layout(location=0) in vec2 uv;
layout(location=0) out vec4 outputColor;
// Direct port of CanvasShader.fragmentMain, including the shared dock/header motion.
void main() {
    vec2 point=uv;
    if(motion.w>.5) {
        if(point.x<motion.x) {
            if(point.x>=motion.x*motion.z) { outputColor=vec4(0); return; }
            point.x+=motion.x*(1-motion.z);
        } else if(point.y<motion.y) {
            if(point.y>=motion.y*motion.z) { outputColor=vec4(0); return; }
            point.y+=motion.y*(1-motion.z);
        }
    }
    vec4 color=texture(sampler2D(image,imageSampler),point);
    outputColor=motion.w>.5 ? color*motion.z : color;
}
