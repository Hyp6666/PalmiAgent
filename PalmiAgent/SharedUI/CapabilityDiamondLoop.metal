#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 palmiCapabilityDiamondLoop(float2 position,
                                                  half4 color,
                                                  float4 boundingRect,
                                                  float time,
                                                  float speed,
                                                  float lineWidth,
                                                  float lines,
                                                  float spacing,
                                                  float channelOffset,
                                                  float patternMod,
                                                  float rotation,
                                                  float scale,
                                                  float2 center,
                                                  half4 color1,
                                                  half4 color2,
                                                  half4 color3,
                                                  half4 background) {
    (void)color;

    float2 size = boundingRect.zw;
    float2 uv = (position * 2.0 - size) / min(size.x, size.y);

    uv = uv / max(scale, 0.0001);
    uv -= center;

    float c = cos(rotation);
    float s = sin(rotation);
    uv = float2(uv.x * c - uv.y * s, uv.x * s + uv.y * c);

    float t = time * speed;
    int count = max(1, int(lines));

    float d = abs(uv.x) + abs(uv.y);
    float pmm = max(patternMod, 0.0001);
    float m = fmod(uv.x * uv.y, pmm);

    float3 channels[3] = {
        float3(color1.rgb),
        float3(color2.rgb),
        float3(color3.rgb)
    };

    float3 glow = float3(0.0);
    for (int channel = 0; channel < 3; channel++) {
        float acc = 0.0;
        for (int line = 0; line < count; line++) {
            float launchOffset = float(line) / max(float(count), 1.0);
            float phase = fract(t - channelOffset * float(channel) + launchOffset);
            float f = phase * spacing - d + m;
            float width = max(lineWidth, 0.0001) * (1.0 + 0.08 * float(line));
            float pulse = smoothstep(width * 3.2, 0.0, abs(f));
            acc += pulse * (0.18 + 0.04 * float(line));
        }
        glow += channels[channel] * acc;
    }

    float vignette = smoothstep(1.45, 0.18, length(uv));
    float3 bg = float3(background.rgb);
    float centerGlint = smoothstep(0.34, 0.0, d);
    centerGlint *= 0.72 + 0.28 * sin(time * 5.4) * sin(time * 5.4);

    float3 centerColor = channels[0] + channels[1] * 0.18 + channels[2] * 0.12;
    float3 col = bg + glow * (0.34 + vignette * 0.34);
    col += centerColor * centerGlint * 0.62;
    col += float3(0.014, 0.018, 0.028) * vignette;
    col = col / (1.0 + col * 0.55);

    return half4(half3(col), 1.0);
}
