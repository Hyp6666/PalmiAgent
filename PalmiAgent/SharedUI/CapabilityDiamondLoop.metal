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
                                                  half4 centerColor,
                                                  half4 color1,
                                                  half4 color2,
                                                  half4 color3,
                                                  half4 background) {
    (void)color;
    (void)channelOffset;

    float2 size = boundingRect.zw;
    float2 uv = (position * 2.0 - size) / min(size.x, size.y);

    uv -= center;
    uv = uv / max(scale, 0.0001);

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
    float centerPulse = 0.0;
    float waveWidth = max(lineWidth * 34.0, 0.52);
    float feather = max(lineWidth * 3.2, 0.045);
    for (int line = 0; line < count; line++) {
        float launchOffset = float(line) / max(float(count), 1.0);
        float phase = fract(t + launchOffset);
        float radius = phase * spacing;
        float warpedDistance = d - m;

        float birth = smoothstep(0.025, waveWidth * 0.95, radius);
        float activeWidth = min(waveWidth, max(radius * 0.92, 0.001)) * birth;
        float innerEdge = radius - activeWidth;
        float outerEdge = radius;

        float afterInnerEdge = smoothstep(innerEdge - feather, innerEdge + feather, warpedDistance);
        float beforeOuterEdge = 1.0 - smoothstep(outerEdge - feather, outerEdge + feather, warpedDistance);
        float band = afterInnerEdge * beforeOuterEdge * birth;
        float corePosition = abs(warpedDistance - mix(innerEdge, outerEdge, 0.54));
        float core = smoothstep(activeWidth * 0.34 + feather, 0.0, corePosition) * birth;
        float ribbonPosition = clamp((warpedDistance - innerEdge) / max(activeWidth, 0.001), 0.0, 1.0);

        float3 ribbonColor = mix(channels[0], channels[1], smoothstep(0.08, 0.58, ribbonPosition));
        ribbonColor = mix(ribbonColor, channels[2], smoothstep(0.50, 1.0, ribbonPosition));

        float lineWeight = 0.40 + 0.045 * float(line);
        glow += ribbonColor * pow(band, 0.58) * lineWeight;
        glow += channels[2] * core * 0.16;

        centerPulse = max(centerPulse, 1.0 - smoothstep(0.0, 0.16, phase));
    }

    float vignette = smoothstep(1.45, 0.18, length(uv));
    float3 bg = float3(background.rgb);
    float centerGlint = smoothstep(0.24, 0.0, d);
    centerGlint *= 0.16 + 0.84 * centerPulse;

    float3 col = bg + glow * (0.56 + vignette * 0.44);
    col += float3(centerColor.rgb) * centerGlint * 0.62;
    col += float3(0.014, 0.018, 0.028) * vignette;
    col = col / (1.0 + col * 0.36);

    return half4(half3(col), 1.0);
}
