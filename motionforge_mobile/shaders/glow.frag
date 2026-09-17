#version 320 es
precision mediump float;
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uIntensity; // قوة التوهج 0.0 .. 3.0
uniform float uThreshold; // عتبة استخراج المناطق الساطعة 0.0 .. 1.0
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec2 texel = 1.0 / uSize;
    vec4 base = texture(uTexture, uv);

    // استخراج المناطق الأكثر سطوعاً فقط (فوق العتبة) ثم تمويهها لإنتاج الهالة
    vec4 glow = vec4(0.0);
    for (float x = -3.0; x <= 3.0; x += 1.0) {
        for (float y = -3.0; y <= 3.0; y += 1.0) {
            vec4 sample_ = texture(uTexture, uv + vec2(x, y) * texel * 2.0);
            float luma = dot(sample_.rgb, vec3(0.299, 0.587, 0.114));
            if (luma > uThreshold) {
                glow += sample_;
            }
        }
    }
    glow /= 49.0;

    fragColor = clamp(base + glow * uIntensity, 0.0, 1.0);
}
