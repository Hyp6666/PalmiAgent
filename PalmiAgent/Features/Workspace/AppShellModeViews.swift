import SwiftUI

enum AppShellMode: String {
    case chat
    case professional

    var title: String {
        switch self {
        case .chat:
            "聊天"
        case .professional:
            "专业"
        }
    }

    var pickerTitle: String {
        switch self {
        case .chat:
            "聊天模式"
        case .professional:
            "专业模式"
        }
    }

    var symbolName: String {
        switch self {
        case .chat:
            "bubble.left.and.bubble.right"
        case .professional:
            "square.grid.2x2"
        }
    }
}

struct AppShellModeChip: View {
    let mode: AppShellMode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: mode.symbolName)
                    .font(.caption.weight(.semibold))
                Text(mode.title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(ModeChipBackground())
        }
        .buttonStyle(.plain)
    }
}

struct AppShellTopFade: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(uiColor: .systemGroupedBackground),
                Color(uiColor: .systemGroupedBackground).opacity(0.94),
                Color(uiColor: .systemGroupedBackground).opacity(0.78),
                Color(uiColor: .systemGroupedBackground).opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 132)
    }
}

struct AppShellTopBar: View {
    let mode: AppShellMode
    let trailingSystemName: String
    let trailingAccessibilityLabel: String
    let onOpenSettings: () -> Void
    let onTrailingAction: () -> Void
    let onSelectMode: (AppShellMode) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            ZStack {
                modeMenu

                HStack {
                    settingsButton

                    Spacer()

                    trailingButton
                }
            }
            .frame(height: 52)
        }
    }

    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Label("设置", systemImage: "gearshape")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.white.opacity(0.10)).interactive(), in: .capsule)
        .accessibilityLabel("设置")
    }

    private var trailingButton: some View {
        Button(action: onTrailingAction) {
            Label("新建", systemImage: trailingSystemName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.white.opacity(0.14)).interactive(), in: .capsule)
        .accessibilityLabel(trailingAccessibilityLabel)
    }

    private var modeMenu: some View {
        Menu {
            Button {
                onSelectMode(.chat)
            } label: {
                Label(AppShellMode.chat.title, systemImage: AppShellMode.chat.symbolName)
            }

            Button {
                onSelectMode(.professional)
            } label: {
                Label(AppShellMode.professional.title, systemImage: AppShellMode.professional.symbolName)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: mode.symbolName)
                    .font(.subheadline.weight(.semibold))
                Text(mode.title)
                    .font(.headline.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .frame(height: 50)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.white.opacity(0.12)).interactive(), in: .capsule)
        .accessibilityLabel("模式")
    }
}

struct AppShellModePickerScreen: View {
    let currentMode: AppShellMode
    let onSelect: (AppShellMode) -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = AppShellModePickerLayout(size: proxy.size)

            ZStack {
                ModeWaveBackground()
                    .ignoresSafeArea()

                modeButton(.chat, layout: layout)
                    .frame(width: layout.buttonWidth, height: layout.buttonHeight)
                    .position(x: layout.centerX, y: layout.chatCenterY)

                modeButton(.professional, layout: layout)
                    .frame(width: layout.buttonWidth, height: layout.buttonHeight)
                    .position(x: layout.centerX, y: layout.professionalCenterY)
            }
        }
        .ignoresSafeArea()
    }

    private func modeButton(_ mode: AppShellMode, layout: AppShellModePickerLayout) -> some View {
        return Button {
            onSelect(mode)
        } label: {
            Text(mode.title)
                .font(.system(size: 29, weight: .heavy, design: .rounded))
                .tracking(2)
                .frame(maxWidth: .infinity)
                .frame(height: layout.buttonHeight)
                .foregroundStyle(mode == .chat ? .black : .white)
                .modifier(
                    NativeGlassCapsule(
                        tint: mode == .chat ? .white : .black,
                        foregroundMode: mode
                    )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ModeChipBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .background {
                    Capsule(style: .continuous)
                        .fill(.white)
                        .glassEffect(.regular.tint(.white.opacity(0.82)), in: .capsule)
                }
        } else {
            content
                .background(
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.94))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.black.opacity(0.06), lineWidth: 0.8)
                        )
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
                )
        }
    }
}

private struct ModeWaveBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let frame = ModeWaveFrame(
                    size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate
                )
                frame.draw(in: context)
            }
        }
    }
}

private struct ModeWaveFrame {
    let size: CGSize
    let time: TimeInterval

    func draw(in context: GraphicsContext) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .color(.white))

        let boundaryY = size.height * 0.5
        let amplitude = interpolate(16, 32, 0.78 + sin(time * 0.22) * 0.08)
        let wavelength = size.width * 0.88

        var blackRegion = Path()
        blackRegion.move(to: .zero)
        blackRegion.addLine(to: CGPoint(x: size.width, y: 0))
        blackRegion.addLine(to: CGPoint(x: size.width, y: boundaryY))

        let steps = 56
        for step in stride(from: steps, through: 0, by: -1) {
            let x = CGFloat(step) / CGFloat(steps) * size.width
            let theta = (x / wavelength) * .pi * 2 + time * 0.72
            let y = boundaryY
                + sin(theta) * amplitude
                + cos(theta * 0.55 - time * 0.28) * amplitude * 0.34
            blackRegion.addLine(to: CGPoint(x: x, y: y))
        }
        blackRegion.closeSubpath()
        context.fill(blackRegion, with: .color(.black))

        drawWaveStroke(in: context, boundaryY: boundaryY, amplitude: amplitude, wavelength: wavelength)
        drawGlyphs(in: context, boundaryY: boundaryY)
    }

    private func drawWaveStroke(in context: GraphicsContext, boundaryY: CGFloat, amplitude: CGFloat, wavelength: CGFloat) {
        var wave = Path()
        wave.move(to: CGPoint(x: 0, y: boundaryY))
        let steps = 72
        for step in 0...steps {
            let x = CGFloat(step) / CGFloat(steps) * size.width
            let theta = (x / wavelength) * .pi * 2 + time * 0.72
            let y = boundaryY
                + sin(theta) * amplitude
                + cos(theta * 0.55 - time * 0.28) * amplitude * 0.34
            wave.addLine(to: CGPoint(x: x, y: y))
        }

        context.stroke(
            wave,
            with: .linearGradient(
                Gradient(colors: [
                    .white.opacity(0.10),
                    .white.opacity(0.86),
                    .black.opacity(0.18)
                ]),
                startPoint: CGPoint(x: 0, y: boundaryY - amplitude),
                endPoint: CGPoint(x: size.width, y: boundaryY + amplitude)
            ),
            style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawGlyphs(in context: GraphicsContext, boundaryY: CGFloat) {
        let glyphs = ["01", "git", "<>", "[]", "{}", "+", "-", "&&", "||", "*", ";", "/", "=", "ls", "::", "cd"]

        for index in 0..<132 {
            let seed = CGFloat(index)
            let x = CGFloat.randomish(seed * 0.37 + 18) * size.width
            let baseY = CGFloat.randomish(seed * 0.63 + 41) * size.height
            let y = baseY + sin(time * (0.16 + Double(index % 7) * 0.018) + Double(index)) * 11
            let onBlack = y < boundaryY
            let accent = sin(time * 1.25 + Double(index) * 0.7) > 0.96
            let size = interpolate(9, 13, CGFloat.randomish(seed * 0.21 + 72))
            let alpha = interpolate(0.06, 0.18, CGFloat.randomish(seed * 0.51 + 9))

            let color: Color
            if onBlack {
                color = accent
                    ? Color(red: 0.52, green: 0.97, blue: 1).opacity(alpha)
                    : .white.opacity(alpha)
            } else {
                color = accent
                    ? Color(red: 1, green: 0.36, blue: 0.48).opacity(alpha * 0.75)
                    : .black.opacity(alpha * 0.72)
            }

            let text = Text(glyphs[index % glyphs.count])
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .foregroundStyle(color)

            context.draw(context.resolve(text), at: CGPoint(x: x, y: y))
        }
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }
}

private struct AppShellModePickerLayout {
    let size: CGSize

    var horizontalInset: CGFloat {
        min(28, size.width * 0.065)
    }

    var buttonHeight: CGFloat {
        min(78, max(72, size.height * 0.084))
    }

    var buttonWidth: CGFloat {
        min(max(196, size.width * 0.58), 248)
    }

    var centerX: CGFloat {
        size.width / 2
    }

    var chatCenterY: CGFloat {
        size.height * 0.24
    }

    var professionalCenterY: CGFloat {
        size.height * 0.76
    }
}

private struct NativeGlassCapsule: ViewModifier {
    let tint: Color
    let foregroundMode: AppShellMode

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .background {
                    Capsule(style: .continuous)
                        .fill(tint)
                        .glassEffect(
                            .regular
                                .tint(tint.opacity(foregroundMode == .chat ? 0.88 : 0.76))
                                .interactive(),
                            in: .capsule
                        )
                }
        } else {
            content
                .background(
                    Capsule(style: .continuous)
                        .fill(tint.opacity(foregroundMode == .chat ? 0.92 : 0.82))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(
                                    foregroundMode == .chat
                                        ? Color.black.opacity(0.06)
                                        : Color.white.opacity(0.12),
                                    lineWidth: 0.8
                                )
                        )
                )
        }
    }
}

private extension CGFloat {
    static func randomish(_ seed: CGFloat) -> CGFloat {
        let value = sin(seed * 12.9898) * 43_758.5453
        return value - floor(value)
    }
}
