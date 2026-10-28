import SwiftUI
import CoreGraphics

// Inspired by dsh-open-file's folded document + format label design; native vectors.
struct PalmiFileIcon: View {
    let presentation: PalmiFilePresentation
    var size: CGFloat = 34
    @Environment(\.colorScheme) private var colorScheme

    init(name: String, mimeType: String? = nil, isDirectory: Bool = false, size: CGFloat = 34) {
        self.presentation = .resolve(name: name, mimeType: mimeType, isDirectory: isDirectory)
        self.size = size
    }

    init(presentation: PalmiFilePresentation, size: CGFloat = 34) {
        self.presentation = presentation
        self.size = size
    }

    var body: some View {
        ZStack {
            if presentation.family == .folder {
                PalmiFolderGlyph()
                    .fill(tint.opacity(0.12))
                PalmiFolderGlyph()
                    .stroke(tint, style: StrokeStyle(lineWidth: size / 24 * 1.4,
                                                    lineCap: .round, lineJoin: .round))
            } else {
                PalmiDocumentGlyph()
                    .fill(tint.opacity(colorScheme == .dark ? 0.10 : 0.035))
                PalmiDocumentGlyph()
                    .stroke(tint, style: StrokeStyle(lineWidth: size / 24 * 1.4,
                                                    lineCap: .round, lineJoin: .round))
                PalmiDocumentFold()
                    .stroke(tint, style: StrokeStyle(lineWidth: size / 24 * 1.3,
                                                    lineCap: .round, lineJoin: .round))
                Text(presentation.label)
                    .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(tint)
                    .frame(width: size * 0.57, height: size * 0.25)
                    .offset(y: size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fontSize: CGFloat {
        size * (presentation.label.count > 4 ? 0.135 : presentation.label.count > 3 ? 0.16 : 0.20)
    }

    private var tint: Color {
        let hex: UInt32
        switch presentation.family {
        case .folder: hex = 0x3478D4
        case .pdf: hex = 0xD93D48
        case .word: hex = 0x3478D4
        case .presentation: hex = 0xD96B32
        case .spreadsheet: hex = 0x278254
        case .table: hex = 0x167F8A
        case .text, .generic: hex = 0x667085
        case .markdown: hex = 0x526172
        case .markup: hex = 0xC4543F
        case .code: hex = 0x5267BD
        case .configuration: hex = 0x78833F
        case .database: hex = 0x7856A8
        case .archive: hex = 0xA76E10
        case .image: hex = 0x8A59BF
        case .audio: hex = 0xB34583
        case .video: hex = 0x446FAD
        }
        let lift: Double = colorScheme == .dark ? 0.27 : 0
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xff) / 255
            return value + (1 - value) * lift
        }
        return Color(red: channel(16), green: channel(8), blue: channel(0))
    }
}

private struct PalmiDocumentGlyph: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 6, y: 22))
        p.addQuadCurve(to: CGPoint(x: 4, y: 20), control: CGPoint(x: 4, y: 22))
        p.addLine(to: CGPoint(x: 4, y: 4))
        p.addQuadCurve(to: CGPoint(x: 6, y: 2), control: CGPoint(x: 4, y: 2))
        p.addLine(to: CGPoint(x: 14, y: 2))
        p.addLine(to: CGPoint(x: 20, y: 8))
        p.addLine(to: CGPoint(x: 20, y: 20))
        p.addQuadCurve(to: CGPoint(x: 18, y: 22), control: CGPoint(x: 20, y: 22))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct PalmiDocumentFold: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 14, y: 2))
        p.addLine(to: CGPoint(x: 14, y: 7))
        p.addQuadCurve(to: CGPoint(x: 15, y: 8), control: CGPoint(x: 14, y: 8))
        p.addLine(to: CGPoint(x: 20, y: 8))
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct PalmiFolderGlyph: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 3, y: 20))
        p.addQuadCurve(to: CGPoint(x: 2, y: 19), control: CGPoint(x: 2, y: 20))
        p.addLine(to: CGPoint(x: 2, y: 6))
        p.addQuadCurve(to: CGPoint(x: 3, y: 5), control: CGPoint(x: 2, y: 5))
        p.addLine(to: CGPoint(x: 9, y: 5))
        p.addLine(to: CGPoint(x: 11, y: 8))
        p.addLine(to: CGPoint(x: 21, y: 8))
        p.addQuadCurve(to: CGPoint(x: 22, y: 9), control: CGPoint(x: 22, y: 8))
        p.addLine(to: CGPoint(x: 22, y: 19))
        p.addQuadCurve(to: CGPoint(x: 21, y: 20), control: CGPoint(x: 22, y: 20))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
