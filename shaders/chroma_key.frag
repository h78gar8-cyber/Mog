#version 320 es
precision mediump float;
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform vec3 uKeyColor;     // لون الخلفية الخضراء المراد إزالتها (افتراضياً أخضر نقي)
uniform float uSimilarity;  // حساسية التطابق اللوني 0.0 .. 1.0
uniform float uSmoothness;  // نعومة حواف القص لتفادي حواف مسننة
uniform sampler2D uTexture; // فريم طبقة الـ Overlay (تحتوي الخلفية الخضراء)

out vec4 fragColor;

// المسافة اللونية في فضاء YCbCr أدق من RGB المباشر لعزل الكروما
// (يفصل الإضاءة عن اللون فيقلل تأثير تفاوت الإضاءة على دقة العزل)
vec2 toChroma(vec3 rgb) {
    float y = dot(rgb, vec3(0.299, 0.587, 0.114));
    float cb = (rgb.b - y) * 0.565;
    float cr = (rgb.r - y) * 0.713;
    return vec2(cb, cr);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 color = texture(uTexture, uv);

    vec2 chromaPixel = toChroma(color.rgb);
    vec2 chromaKey = toChroma(uKeyColor);
    float distance = length(chromaPixel - chromaKey);

    float alpha = smoothstep(uSimilarity, uSimilarity + uSmoothness, distance);

    // إزالة بسيطة لـ "التسرب الأخضر" (Spill) على حواف الموضوع
    vec3 despilled = color.rgb;
    float greenExcess = color.g - max(color.r, color.b);
    if (greenExcess > 0.0) {
        despilled.g -= greenExcess * 0.5;
    }

    fragColor = vec4(despilled, color.a * alpha);
}
