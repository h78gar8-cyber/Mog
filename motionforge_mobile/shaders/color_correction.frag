#version 320 es
precision mediump float;
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uBrightness; // -1.0 .. 1.0
uniform float uContrast;   // 0.0 .. 2.0
uniform float uSaturation; // 0.0 .. 2.0
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 color = texture(uTexture, uv);

    // السطوع
    color.rgb += uBrightness;

    // التباين حول نقطة المنتصف الرمادية
    color.rgb = (color.rgb - 0.5) * uContrast + 0.5;

    // التشبع اللوني عبر تحويل الإضاءة النسبية (Luma) القياسي
    float luma = dot(color.rgb, vec3(0.299, 0.587, 0.114));
    color.rgb = mix(vec3(luma), color.rgb, uSaturation);

    fragColor = clamp(color, 0.0, 1.0);
}
