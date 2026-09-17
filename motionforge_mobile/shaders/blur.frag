// blur.frag
// ============================================================
// Fragment Shader يُصرَّف بواسطة Impeller مباشرة إلى Metal (iOS)
// أو Vulkan/OpenGL ES (Android). يُحمَّل في Dart عبر:
//
//   final program = await FragmentProgram.fromAsset('shaders/blur.frag');
//   final shader = program.fragmentShader()
//     ..setFloat(0, radius)
//     ..setImageSampler(0, image);
//   canvas.drawRect(rect, Paint()..shader = shader);
//
// التنفيذ يحدث بالكامل على GPU، بالتوازي عبر آلاف الأنوية الرسومية
// الصغيرة، وهذا ما يمنح معاينة فورية (Real-time) بلا أي تقطيع حتى
// على فيديو بدقة عالية أثناء السحب الحي للتايم لاين.
// ============================================================

#version 320 es
precision mediump float;

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;      // أبعاد المساحة المرسومة
uniform float uRadius;   // قوة الضبابية (تُربط بـ Slider في الـ Inspector)
uniform sampler2D uTexture;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec2 texel = 1.0 / uSize;

    vec4 sum = vec4(0.0);
    float total = 0.0;

    // Gaussian Blur مبسّط بعينات متعددة (Box-approximation ثنائي الاتجاه)
    for (float x = -4.0; x <= 4.0; x += 1.0) {
        for (float y = -4.0; y <= 4.0; y += 1.0) {
            float weight = exp(-(x * x + y * y) / (2.0 * uRadius * uRadius + 0.001));
            vec2 offset = vec2(x, y) * texel * uRadius;
            sum += texture(uTexture, uv + offset) * weight;
            total += weight;
        }
    }

    fragColor = sum / total;
}
