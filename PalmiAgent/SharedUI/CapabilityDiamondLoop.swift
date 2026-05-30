import SwiftUI

struct CapabilityDiamondLoop: View {
    var centerPoint: CGPoint?
    var speed: Float = 0.46
    var lineWidth: Float = 0.016
    var lines: Int = 9
    var spacing: Float = 4.6
    var channelOffset: Float = 0.018
    var patternMod: Float = 0.12
    var rotation: Float = 0.0
    var scale: Float = 1.18

    @State private var start: Date = .now

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation) { context in
                let size = proxy.size
                let center = normalizedCenter(in: size)
                let elapsed = Float(context.date.timeIntervalSince(start))

                Color.black
                    .colorEffect(
                        Shader(
                            function: ShaderFunction(
                                library: .default,
                                name: "palmiCapabilityDiamondLoop"
                            ),
                            arguments: [
                                .boundingRect,
                                .float(elapsed),
                                .float(speed),
                                .float(lineWidth),
                                .float(Float(lines)),
                                .float(spacing),
                                .float(channelOffset),
                                .float(patternMod),
                                .float(rotation),
                                .float(scale),
                                .float2(center.x, center.y),
                                .color(Color(red: 1.00, green: 0.10, blue: 0.05)),
                                .color(Color(red: 0.18, green: 1.00, blue: 0.70)),
                                .color(Color(red: 0.32, green: 0.38, blue: 1.00)),
                                .color(.black)
                            ]
                        )
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private func normalizedCenter(in size: CGSize) -> SIMD2<Float> {
        let fallback = CGPoint(x: size.width * 0.78, y: size.height * 0.24)
        let point = centerPoint ?? fallback
        let minSide = max(min(size.width, size.height), 1)

        return SIMD2(
            Float((point.x * 2 - size.width) / minSide),
            Float((point.y * 2 - size.height) / minSide)
        )
    }
}
