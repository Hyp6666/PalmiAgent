import SwiftUI

#if os(iOS)
import UIKit
#endif

struct CapabilityDiamondLoop: View {
    var centerPoint: CGPoint?
    var speed: Float = 0.0575
    var lineWidth: Float = 0.016
    var lines: Int = 5
    var spacing: Float = 4.6
    var channelOffset: Float = 0.018
    var patternMod: Float = 0.12
    var rotation: Float = 0.0
    var scale: Float = 1.18

    @State private var start: Date = .now
    @State private var hapticTask: Task<Void, Never>?

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
                                .color(Color(red: 255.0 / 255.0, green: 46.0 / 255.0, blue: 0.0 / 255.0)),
                                .color(Color(red: 232.0 / 255.0, green: 127.0 / 255.0, blue: 36.0 / 255.0)),
                                .color(Color(red: 255.0 / 255.0, green: 200.0 / 255.0, blue: 30.0 / 255.0)),
                                .color(Color(red: 254.0 / 255.0, green: 253.0 / 255.0, blue: 223.0 / 255.0)),
                                .color(.black)
                            ]
                        )
                    )
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            startHapticLoop()
        }
        .onDisappear {
            hapticTask?.cancel()
            hapticTask = nil
        }
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

    private func startHapticLoop() {
        hapticTask?.cancel()

        #if os(iOS)
        let waveInterval = max(1.2, Double(1 / max(speed * Float(max(lines, 1)), 0.001)))
        hapticTask = Task { @MainActor in
            while !Task.isCancelled {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.prepare()
                generator.impactOccurred(intensity: 0.46)

                try? await Task.sleep(nanoseconds: 46_000_000)
                generator.impactOccurred(intensity: 0.34)

                try? await Task.sleep(nanoseconds: 46_000_000)
                generator.impactOccurred(intensity: 0.24)

                try? await Task.sleep(nanoseconds: UInt64(waveInterval * 1_000_000_000))
            }
        }
        #endif
    }
}
