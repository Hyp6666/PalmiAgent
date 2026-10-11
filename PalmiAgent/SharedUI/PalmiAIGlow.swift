import SwiftUI

/// Palmi 正在处理时的彩虹光效：沿形状内缘流动的一圈光，柔光层 + 细描边层。
struct PalmiAIGlow<S: InsettableShape>: ViewModifier {
    let shape: S
    let isActive: Bool
    var lineWidth: CGFloat = 3

    private static var colors: [Color] {
        [
            Color(red: 0.36, green: 0.55, blue: 1.0),
            Color(red: 0.66, green: 0.42, blue: 1.0),
            Color(red: 1.0, green: 0.42, blue: 0.72),
            Color(red: 1.0, green: 0.62, blue: 0.32),
            Color(red: 0.98, green: 0.86, blue: 0.36),
            Color(red: 0.38, green: 0.88, blue: 0.86),
            Color(red: 0.36, green: 0.55, blue: 1.0)
        ]
    }

    func body(content: Content) -> some View {
        content.overlay {
            if isActive {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
                    let gradient = AngularGradient(colors: Self.colors, center: .center, angle: .degrees(phase * 360))
                    ZStack {
                        shape.strokeBorder(gradient, lineWidth: lineWidth * 2.2)
                            .blur(radius: lineWidth * 1.8)
                            .opacity(0.75)
                        shape.strokeBorder(gradient, lineWidth: lineWidth)
                    }
                    .clipShape(shape)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isActive)
    }
}

extension View {
    func palmiAIGlow<S: InsettableShape>(_ shape: S, isActive: Bool, lineWidth: CGFloat = 3) -> some View {
        modifier(PalmiAIGlow(shape: shape, isActive: isActive, lineWidth: lineWidth))
    }
}
