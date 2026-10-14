import SwiftUI
import UIKit

/// Palmi 正在处理时的内缘柔光；入口、标签页和网页共用同一套表现。
/// 观感参照 Apple Intelligence 边缘光：多层由清到雾的柔光叠加，色块随机漂移并缓慢环绕，轻微呼吸。
struct PalmiAIGlow<S: InsettableShape>: ViewModifier {
    let shape: S
    let isActive: Bool
    var lineWidth: CGFloat = 3

    func body(content: Content) -> some View {
        content.overlay {
            PalmiAIGlowLayer(shape: shape, isActive: isActive, lineWidth: lineWidth)
        }
    }
}

/// 柔光图层本体。可直接放进 background，让文字和图标保持在光的上面。
struct PalmiAIGlowLayer<S: InsettableShape>: View {
    let shape: S
    let isActive: Bool
    /// 光的基准粗细；最外层雾光约为它的 3 倍深。
    var lineWidth: CGFloat = 3

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var field = PalmiGlowField()
    @State private var elapsed: TimeInterval = 0
    @State private var runStartedAt: Date?
    @State private var isVisible = false

    private var shouldAnimate: Bool {
        isActive && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !shouldAnimate)) { context in
            let time = elapsed + (runStartedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0)
            let gradient = field.gradient(at: time, isStatic: reduceMotion)
            let breath = reduceMotion ? 0 : field.breath(at: time)
            let w = max(1, lineWidth) * (1 + CGFloat(breath) * 0.12)
            let isDark = colorScheme == .dark

            ZStack {
                // 外层雾光：宽而深的模糊，形成向内渗出的“水汽”。
                shape.strokeBorder(gradient, lineWidth: w * 3.2)
                    .blur(radius: w * 2.4)
                    .opacity(isDark ? 0.9 : 0.78)
                // 中层：颜色主体，带出流动的色块。
                shape.strokeBorder(gradient, lineWidth: w * 1.5)
                    .blur(radius: w * 0.9)
                    .opacity(isDark ? 0.92 : 0.85)
                // 贴边一层仍做轻度模糊，只提亮边缘，不形成硬实线。
                shape.strokeBorder(gradient, lineWidth: w * 0.5)
                    .blur(radius: max(0.6, w * 0.35))
                    .opacity(isDark ? 0.95 : 0.9)
            }
            .clipShape(shape)
            .drawingGroup()
            .opacity(0.88 + breath * 0.12)
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.6), value: isVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: isActive, initial: true) { _, active in
            isVisible = active
        }
        .onChange(of: shouldAnimate, initial: true) { _, isRunning in
            // 暂停时累计已走时间，恢复后从原来的色场继续，不跳色。
            if isRunning {
                runStartedAt = Date()
            } else if let startedAt = runStartedAt {
                elapsed += max(0, Date().timeIntervalSince(startedAt))
                runStartedAt = nil
            }
        }
    }
}

/// 柔光配色：Apple Intelligence 一类的冷暖过渡，不用全色相彩虹。
enum PalmiAIGlowPalette {
    static let colors: [Color] = [
        Color(red: 0.737, green: 0.510, blue: 0.953), // 紫
        Color(red: 0.961, green: 0.725, blue: 0.918), // 粉
        Color(red: 0.553, green: 0.624, blue: 1.000), // 蓝紫
        Color(red: 1.000, green: 0.404, blue: 0.471), // 珊瑚
        Color(red: 1.000, green: 0.729, blue: 0.443), // 桃
        Color(red: 0.776, green: 0.525, blue: 1.000)  // 淡紫
    ]

    @MainActor private static var symbolCache: [String: UIImage] = [:]

    /// 用柔光配色填充的 SF Symbol，用于系统菜单这类只能放图片的位置。
    @MainActor
    static func symbolImage(_ name: String, pointSize: CGFloat = 17) -> UIImage {
        if let cached = symbolCache[name] { return cached }
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else { return UIImage() }
        let size = symbol.size
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let uiColors = [
                UIColor(red: 0.553, green: 0.624, blue: 1.000, alpha: 1),
                UIColor(red: 0.737, green: 0.510, blue: 0.953, alpha: 1),
                UIColor(red: 1.000, green: 0.404, blue: 0.471, alpha: 1),
                UIColor(red: 1.000, green: 0.729, blue: 0.443, alpha: 1)
            ]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: uiColors.map(\.cgColor) as CFArray,
                                      locations: [0, 0.38, 0.72, 1])!
            symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: size))
            // 只在符号笔画内填渐变。
            cg.setBlendMode(.sourceIn)
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }.withRenderingMode(.alwaysOriginal)
        symbolCache[name] = image
        return image
    }
}

/// 色场：每个色标在自己的位置附近随机漂移（各自节奏），整体再缓慢环绕，形成流动而非匀速转圈的灯条。
private struct PalmiGlowField {
    private let stopDrifts = PalmiAIGlowPalette.colors.indices.map { _ in PalmiGlowDrift(interval: 1.4...2.8) }
    private let swirl = PalmiGlowDrift(interval: 3.5...6)
    private let centerX = PalmiGlowDrift(interval: 2.5...4.5)
    private let centerY = PalmiGlowDrift(interval: 2.5...4.5)
    private let breathPhase = Double.random(in: 0...(2 * .pi))
    private let rotationSpeed = Double.random(in: 18...26) // 度/秒，约 15–20 秒环绕一圈

    func gradient(at time: TimeInterval, isStatic: Bool) -> AngularGradient {
        let colors = PalmiAIGlowPalette.colors
        let count = colors.count
        var stops: [Gradient.Stop] = colors.enumerated().map { index, color in
            let base = Double(index) / Double(count)
            let jitter = isStatic ? 0 : stopDrifts[index].value(at: time) * 0.07
            return Gradient.Stop(color: color, location: CGFloat(base + jitter + 0.07))
        }
        // 首尾同色闭合，环绕时没有接缝。
        stops.insert(Gradient.Stop(color: colors[count - 1], location: 0), at: 0)
        stops.append(Gradient.Stop(color: colors[count - 1], location: 1))
        let angle = isStatic ? 0 : time * rotationSpeed + swirl.value(at: time) * 40
        let center = isStatic ? UnitPoint.center : UnitPoint(
            x: 0.5 + CGFloat(centerX.value(at: time)) * 0.12,
            y: 0.5 + CGFloat(centerY.value(at: time)) * 0.10
        )
        return AngularGradient(gradient: Gradient(stops: stops.sorted { $0.location < $1.location }),
                               center: center, angle: .degrees(angle))
    }

    func breath(at time: TimeInterval) -> Double {
        sin(time * 0.9 + breathPhase) * 0.65 + sin(time * 0.37 + breathPhase * 1.7) * 0.35
    }
}

/// 在随机锚点之间平滑缓动；段首尾速度为零，可由时间直接求值，暂停恢复无跳变。
private struct PalmiGlowDrift {
    private let seed = UInt64.random(in: 0...UInt64.max)
    private let segmentDuration: TimeInterval
    private let offset: TimeInterval

    init(interval: ClosedRange<TimeInterval>) {
        segmentDuration = Double.random(in: interval)
        offset = Double.random(in: 0...segmentDuration)
    }

    func value(at time: TimeInterval) -> Double {
        let position = (max(0, time) + offset) / segmentDuration
        let segment = UInt64(floor(position))
        let progress = position - floor(position)
        let eased = progress * progress * (3 - 2 * progress)
        let from = anchor(segment)
        return from + (anchor(segment &+ 1) - from) * eased
    }

    private func anchor(_ segment: UInt64) -> Double {
        var hash = seed &+ (segment &* 0x9E3779B97F4A7C15)
        hash = (hash ^ (hash >> 30)) &* 0xBF58476D1CE4E5B9
        hash = (hash ^ (hash >> 27)) &* 0x94D049BB133111EB
        hash ^= hash >> 31
        return Double(hash >> 11) / 9_007_199_254_740_991 * 2 - 1
    }
}

extension View {
    func palmiAIGlow<S: InsettableShape>(_ shape: S, isActive: Bool, lineWidth: CGFloat = 3) -> some View {
        modifier(PalmiAIGlow(shape: shape, isActive: isActive, lineWidth: lineWidth))
    }
}
