import AppKit
import Foundation
import SwiftUI

struct PalmiIconRecipe: Decodable {
    let version: Int
    let canvas: Double
    let artworkScale: Double?
    let background: Background
    let face: Face
    let highlight: Highlight
    let eyeGlints: EyeGlints
    let eyes: Eyes
    let mouth: Mouth

    struct Background: Decodable {
        let topLeading: HexColor
        let bottomTrailing: HexColor
        let warmAccent: HexColor
        let warmAccentOpacity: Double
    }

    struct Face: Decodable {
        let centerX: Double
        let centerY: Double
        let width: Double
        let height: Double
        let cornerRadius: Double
        let fill: HexColor
        let fillOpacity: Double
        let rim: HexColor
        let rimOpacity: Double
        let rimWidth: Double
        let innerRimOpacity: Double
        let innerRimWidth: Double
    }

    struct Highlight: Decodable {
        let startX: Double
        let startY: Double
        let control1X: Double
        let control1Y: Double
        let control2X: Double
        let control2Y: Double
        let endX: Double
        let endY: Double
        let lineWidth: Double
        let fill: HexColor
        let opacity: Double
        let blur: Double
    }

    struct EyeGlints: Decodable {
        let xOffset: Double
        let yOffset: Double
        let diameter: Double
        let fill: HexColor
        let opacity: Double
    }

    struct Eyes: Decodable {
        let centerY: Double
        let leftCenterX: Double
        let rightCenterX: Double
        let width: Double
        let height: Double
        let cornerRadius: Double
        let fill: HexColor
        let opacity: Double
    }

    struct Mouth: Decodable {
        let centerX: Double
        let centerY: Double
        let width: Double
        let height: Double
        let lineWidth: Double
        let curveDepth: Double
        let fill: HexColor
        let opacity: Double
    }
}

struct HexColor: Decodable {
    let rawValue: String

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    var color: Color {
        let rgb = Self.rgbComponents(from: rawValue)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private static func rgbComponents(from hex: String) -> (red: Double, green: Double, blue: Double) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return (1, 1, 1)
        }
        return (
            Double((value >> 16) & 0xff) / 255.0,
            Double((value >> 8) & 0xff) / 255.0,
            Double(value & 0xff) / 255.0
        )
    }
}

enum PalmiIconLayer: String, CaseIterable {
    case background = "00-background"
    case face = "10-face"
    case rim = "20-face-rim"
    case highlight = "30-highlight"
    case eyeGlints = "35-eye-glints"
    case features = "40-features"
    case preview = "palmi-icon-preview"
}

enum PalmiAppIconVariant: String, CaseIterable {
    case `default`
    case dark
    case tinted

    var fileName: String {
        switch self {
        case .default:
            return "palmi-app-icon-default.png"
        case .dark:
            return "palmi-app-icon-dark.png"
        case .tinted:
            return "palmi-app-icon-tinted.png"
        }
    }
}

struct PalmiIconArtwork: View {
    let recipe: PalmiIconRecipe
    let layer: PalmiIconLayer
    var variant: PalmiAppIconVariant = .default

    var body: some View {
        ZStack {
            if layer == .background || layer == .preview {
                background
            }

            ZStack {
                if layer == .face || layer == .preview {
                    face
                }
                if layer == .rim || layer == .preview {
                    rim
                }
                if layer == .highlight || layer == .preview {
                    highlight
                }
                if layer == .features || layer == .preview {
                    features
                }
                if layer == .eyeGlints || layer == .preview {
                    eyeGlints
                }
            }
            .scaleEffect(recipe.artworkScale ?? 1, anchor: .center)
        }
        .frame(width: recipe.canvas, height: recipe.canvas)
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: backgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(recipe.background.warmAccent.color.opacity(warmAccentOpacity))
                .frame(width: recipe.canvas * 0.42, height: recipe.canvas * 0.42)
                .position(x: recipe.canvas * 0.08, y: recipe.canvas * 0.92)
        }
    }

    private var backgroundColors: [Color] {
        switch variant {
        case .default:
            return [recipe.background.topLeading.color, recipe.background.bottomTrailing.color]
        case .dark:
            return [
                Color(red: 0.13, green: 0.15, blue: 0.17),
                Color(red: 0.02, green: 0.025, blue: 0.03)
            ]
        case .tinted:
            return [
                Color(red: 0.88, green: 0.90, blue: 0.92),
                Color(red: 0.48, green: 0.53, blue: 0.58)
            ]
        }
    }

    private var warmAccentOpacity: Double {
        switch variant {
        case .default:
            return recipe.background.warmAccentOpacity
        case .dark:
            return 0.03
        case .tinted:
            return 0
        }
    }

    private var face: some View {
        RoundedRectangle(cornerRadius: recipe.face.cornerRadius, style: .continuous)
            .fill(faceFill.opacity(faceOpacity))
            .frame(width: recipe.face.width, height: recipe.face.height)
            .position(x: recipe.face.centerX, y: recipe.face.centerY)
    }

    private var faceFill: Color {
        switch variant {
        case .default:
            return recipe.face.fill.color
        case .dark:
            return Color(red: 0.82, green: 0.89, blue: 0.90)
        case .tinted:
            return Color(red: 0.92, green: 0.94, blue: 0.95)
        }
    }

    private var faceOpacity: Double {
        switch variant {
        case .default:
            return recipe.face.fillOpacity
        case .dark:
            return 0.82
        case .tinted:
            return 0.84
        }
    }

    private var rim: some View {
        ZStack {
            RoundedRectangle(cornerRadius: recipe.face.cornerRadius, style: .continuous)
                .stroke(rimFill.opacity(rimOpacity), lineWidth: recipe.face.rimWidth)

            RoundedRectangle(cornerRadius: recipe.face.cornerRadius - 12, style: .continuous)
                .stroke(rimFill.opacity(innerRimOpacity), lineWidth: recipe.face.innerRimWidth)
                .padding(recipe.face.innerRimWidth)
        }
        .frame(width: recipe.face.width, height: recipe.face.height)
        .position(x: recipe.face.centerX, y: recipe.face.centerY)
    }

    private var rimFill: Color {
        switch variant {
        case .default, .dark:
            return recipe.face.rim.color
        case .tinted:
            return Color(red: 1, green: 1, blue: 1)
        }
    }

    private var rimOpacity: Double {
        switch variant {
        case .default:
            return recipe.face.rimOpacity
        case .dark:
            return 0.42
        case .tinted:
            return 0.48
        }
    }

    private var innerRimOpacity: Double {
        switch variant {
        case .default:
            return recipe.face.innerRimOpacity
        case .dark:
            return 0.12
        case .tinted:
            return 0.18
        }
    }

    private var highlight: some View {
        EdgeGlintShape(highlight: recipe.highlight)
            .stroke(
                recipe.highlight.fill.color.opacity(recipe.highlight.opacity),
                style: StrokeStyle(lineWidth: recipe.highlight.lineWidth, lineCap: .round, lineJoin: .round)
            )
            .frame(width: recipe.canvas, height: recipe.canvas)
            .blur(radius: recipe.highlight.blur)
    }

    private var features: some View {
        ZStack {
            RoundedRectangle(cornerRadius: recipe.eyes.cornerRadius, style: .continuous)
                .fill(featureFill.opacity(recipe.eyes.opacity))
                .frame(width: recipe.eyes.width, height: recipe.eyes.height)
                .position(x: recipe.eyes.leftCenterX, y: recipe.eyes.centerY)

            RoundedRectangle(cornerRadius: recipe.eyes.cornerRadius, style: .continuous)
                .fill(featureFill.opacity(recipe.eyes.opacity))
                .frame(width: recipe.eyes.width, height: recipe.eyes.height)
                .position(x: recipe.eyes.rightCenterX, y: recipe.eyes.centerY)

            SmileShape(depth: recipe.mouth.curveDepth)
                .stroke(
                    featureFill.opacity(recipe.mouth.opacity),
                    style: StrokeStyle(lineWidth: recipe.mouth.lineWidth, lineCap: .round, lineJoin: .round)
                )
                .frame(width: recipe.mouth.width, height: recipe.mouth.height)
                .position(x: recipe.mouth.centerX, y: recipe.mouth.centerY)
        }
    }

    private var featureFill: Color {
        switch variant {
        case .default, .dark:
            return recipe.eyes.fill.color
        case .tinted:
            return Color(red: 0.09, green: 0.10, blue: 0.11)
        }
    }

    private var eyeGlints: some View {
        ZStack {
            Circle()
                .fill(recipe.eyeGlints.fill.color.opacity(recipe.eyeGlints.opacity))
                .frame(width: recipe.eyeGlints.diameter, height: recipe.eyeGlints.diameter)
                .position(
                    x: recipe.eyes.leftCenterX + recipe.eyeGlints.xOffset,
                    y: recipe.eyes.centerY + recipe.eyeGlints.yOffset
                )

            Circle()
                .fill(recipe.eyeGlints.fill.color.opacity(recipe.eyeGlints.opacity))
                .frame(width: recipe.eyeGlints.diameter, height: recipe.eyeGlints.diameter)
                .position(
                    x: recipe.eyes.rightCenterX + recipe.eyeGlints.xOffset,
                    y: recipe.eyes.centerY + recipe.eyeGlints.yOffset
                )
        }
    }
}

struct SmileShape: Shape {
    let depth: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.midY + depth)
        )
        return path
    }
}

struct EdgeGlintShape: Shape {
    let highlight: PalmiIconRecipe.Highlight

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: highlight.startX, y: highlight.startY))
        path.addCurve(
            to: CGPoint(x: highlight.endX, y: highlight.endY),
            control1: CGPoint(x: highlight.control1X, y: highlight.control1Y),
            control2: CGPoint(x: highlight.control2X, y: highlight.control2Y)
        )
        return path
    }
}

@available(macOS 13.0, *)
@MainActor
enum Renderer {
    static func run(arguments: [String]) throws {
        let recipeURL = URL(fileURLWithPath: value(after: "--recipe", in: arguments) ?? "Design/PalmiIcon/PalmiIconRecipe.json")
        let outputURL = URL(fileURLWithPath: value(after: "--out", in: arguments) ?? "artifacts/palmi-icon/v1")
        let pngURL = outputURL.appendingPathComponent("png-layers", isDirectory: true)
        let svgURL = outputURL.appendingPathComponent("svg-layers", isDirectory: true)

        try FileManager.default.createDirectory(at: pngURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: svgURL, withIntermediateDirectories: true)

        let recipe = try JSONDecoder().decode(PalmiIconRecipe.self, from: Data(contentsOf: recipeURL))

        for layer in PalmiIconLayer.allCases {
            let image = try render(recipe: recipe, layer: layer)
            try writePNG(image, to: pngURL.appendingPathComponent("\(layer.rawValue).png"))
        }

        try writeSVGLayers(recipe: recipe, to: svgURL)
        try FileManager.default.copyItemReplacingExisting(
            at: recipeURL,
            to: outputURL.appendingPathComponent("PalmiIconRecipe.json")
        )

        if let appIconOutputPath = value(after: "--appicon-out", in: arguments) {
            try renderAppIcons(recipe: recipe, to: URL(fileURLWithPath: appIconOutputPath))
        }

        print("Rendered Palmi icon artwork to \(outputURL.path)")
        print("Preview: \(pngURL.appendingPathComponent("palmi-icon-preview.png").path)")
        print("Icon Composer SVG layers: \(svgURL.path)")
        print("Icon Composer PNG layers: \(pngURL.path)")
    }

    private static func render(recipe: PalmiIconRecipe, layer: PalmiIconLayer) throws -> NSImage {
        let content = PalmiIconArtwork(recipe: recipe, layer: layer)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: recipe.canvas, height: recipe.canvas)
        renderer.scale = 1
        renderer.isOpaque = layer == .background || layer == .preview

        guard let image = renderer.nsImage else {
            throw RenderError.renderFailed(layer.rawValue)
        }
        return image
    }

    private static func renderAppIcons(recipe: PalmiIconRecipe, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for variant in PalmiAppIconVariant.allCases {
            let content = PalmiIconArtwork(recipe: recipe, layer: .preview, variant: variant)
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: recipe.canvas, height: recipe.canvas)
            renderer.scale = 1
            renderer.isOpaque = true

            guard let image = renderer.nsImage else {
                throw RenderError.renderFailed("app-icon-\(variant.rawValue)")
            }

            try writePNG(image, to: directory.appendingPathComponent(variant.fileName))
        }

        try appIconContentsJSON().write(
            to: directory.appendingPathComponent("Contents.json"),
            atomically: true,
            encoding: .utf8
        )

        print("App icon asset set: \(directory.path)")
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed(url.path)
        }
        try pngData.write(to: url)
    }

    private static func writeSVGLayers(recipe: PalmiIconRecipe, to directory: URL) throws {
        try svgFace(recipe).write(
            to: directory.appendingPathComponent("10-face.svg"),
            atomically: true,
            encoding: .utf8
        )
        try svgRim(recipe).write(
            to: directory.appendingPathComponent("20-face-rim.svg"),
            atomically: true,
            encoding: .utf8
        )
        try svgHighlight(recipe).write(
            to: directory.appendingPathComponent("30-highlight.svg"),
            atomically: true,
            encoding: .utf8
        )
        try svgEyeGlints(recipe).write(
            to: directory.appendingPathComponent("35-eye-glints.svg"),
            atomically: true,
            encoding: .utf8
        )
        try svgFeatures(recipe).write(
            to: directory.appendingPathComponent("40-features.svg"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func svgHeader(_ recipe: PalmiIconRecipe) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(recipe.canvas))" height="\(Int(recipe.canvas))" viewBox="0 0 \(Int(recipe.canvas)) \(Int(recipe.canvas))">
        """
    }

    private static func svgDocument(recipe: PalmiIconRecipe, content: String) -> String {
        guard let scale = recipe.artworkScale, scale != 1 else {
            return """
            \(svgHeader(recipe))
            \(content)
            </svg>
            """
        }

        let center = recipe.canvas / 2
        return """
        \(svgHeader(recipe))
          <g transform="translate(\(center) \(center)) scale(\(scale)) translate(-\(center) -\(center))">
        \(content)
          </g>
        </svg>
        """
    }

    private static func svgFace(_ recipe: PalmiIconRecipe) -> String {
        let x = recipe.face.centerX - recipe.face.width / 2
        let y = recipe.face.centerY - recipe.face.height / 2
        return svgDocument(
            recipe: recipe,
            content: "    <rect x=\"\(x)\" y=\"\(y)\" width=\"\(recipe.face.width)\" height=\"\(recipe.face.height)\" rx=\"\(recipe.face.cornerRadius)\" fill=\"\(recipe.face.fill.rawValue)\" fill-opacity=\"\(recipe.face.fillOpacity)\"/>"
        )
    }

    private static func svgRim(_ recipe: PalmiIconRecipe) -> String {
        let x = recipe.face.centerX - recipe.face.width / 2
        let y = recipe.face.centerY - recipe.face.height / 2
        return svgDocument(
            recipe: recipe,
            content: "    <rect x=\"\(x)\" y=\"\(y)\" width=\"\(recipe.face.width)\" height=\"\(recipe.face.height)\" rx=\"\(recipe.face.cornerRadius)\" fill=\"none\" stroke=\"\(recipe.face.rim.rawValue)\" stroke-opacity=\"\(recipe.face.rimOpacity)\" stroke-width=\"\(recipe.face.rimWidth)\"/>"
        )
    }

    private static func svgHighlight(_ recipe: PalmiIconRecipe) -> String {
        return svgDocument(
            recipe: recipe,
            content: "    <path d=\"M \(recipe.highlight.startX) \(recipe.highlight.startY) C \(recipe.highlight.control1X) \(recipe.highlight.control1Y) \(recipe.highlight.control2X) \(recipe.highlight.control2Y) \(recipe.highlight.endX) \(recipe.highlight.endY)\" fill=\"none\" stroke=\"\(recipe.highlight.fill.rawValue)\" stroke-opacity=\"\(recipe.highlight.opacity)\" stroke-width=\"\(recipe.highlight.lineWidth)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        )
    }

    private static func svgFeatures(_ recipe: PalmiIconRecipe) -> String {
        let eyeY = recipe.eyes.centerY - recipe.eyes.height / 2
        let leftX = recipe.eyes.leftCenterX - recipe.eyes.width / 2
        let rightX = recipe.eyes.rightCenterX - recipe.eyes.width / 2
        let mouthLeftX = recipe.mouth.centerX - recipe.mouth.width / 2
        let mouthRightX = recipe.mouth.centerX + recipe.mouth.width / 2
        let mouthY = recipe.mouth.centerY
        let controlY = recipe.mouth.centerY + recipe.mouth.curveDepth

        return svgDocument(
            recipe: recipe,
            content: """
                <rect x="\(leftX)" y="\(eyeY)" width="\(recipe.eyes.width)" height="\(recipe.eyes.height)" rx="\(recipe.eyes.cornerRadius)" fill="\(recipe.eyes.fill.rawValue)" fill-opacity="\(recipe.eyes.opacity)"/>
                <rect x="\(rightX)" y="\(eyeY)" width="\(recipe.eyes.width)" height="\(recipe.eyes.height)" rx="\(recipe.eyes.cornerRadius)" fill="\(recipe.eyes.fill.rawValue)" fill-opacity="\(recipe.eyes.opacity)"/>
                <path d="M \(mouthLeftX) \(mouthY) Q \(recipe.mouth.centerX) \(controlY) \(mouthRightX) \(mouthY)" fill="none" stroke="\(recipe.mouth.fill.rawValue)" stroke-opacity="\(recipe.mouth.opacity)" stroke-width="\(recipe.mouth.lineWidth)" stroke-linecap="round" stroke-linejoin="round"/>
            """
        )
    }

    private static func svgEyeGlints(_ recipe: PalmiIconRecipe) -> String {
        let leftX = recipe.eyes.leftCenterX + recipe.eyeGlints.xOffset
        let rightX = recipe.eyes.rightCenterX + recipe.eyeGlints.xOffset
        let y = recipe.eyes.centerY + recipe.eyeGlints.yOffset
        let radius = recipe.eyeGlints.diameter / 2

        return svgDocument(
            recipe: recipe,
            content: """
                <circle cx="\(leftX)" cy="\(y)" r="\(radius)" fill="\(recipe.eyeGlints.fill.rawValue)" fill-opacity="\(recipe.eyeGlints.opacity)"/>
                <circle cx="\(rightX)" cy="\(y)" r="\(radius)" fill="\(recipe.eyeGlints.fill.rawValue)" fill-opacity="\(recipe.eyeGlints.opacity)"/>
            """
        )
    }

    private static func appIconContentsJSON() -> String {
        """
        {
          "images" : [
            {
              "filename" : "\(PalmiAppIconVariant.default.fileName)",
              "idiom" : "universal",
              "platform" : "ios",
              "size" : "1024x1024"
            },
            {
              "appearances" : [
                {
                  "appearance" : "luminosity",
                  "value" : "dark"
                }
              ],
              "filename" : "\(PalmiAppIconVariant.dark.fileName)",
              "idiom" : "universal",
              "platform" : "ios",
              "size" : "1024x1024"
            },
            {
              "appearances" : [
                {
                  "appearance" : "luminosity",
                  "value" : "tinted"
                }
              ],
              "filename" : "\(PalmiAppIconVariant.tinted.fileName)",
              "idiom" : "universal",
              "platform" : "ios",
              "size" : "1024x1024"
            }
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }
        """
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

enum RenderError: Error, CustomStringConvertible {
    case renderFailed(String)
    case pngEncodingFailed(String)

    var description: String {
        switch self {
        case .renderFailed(let layer):
            return "Could not render layer \(layer)."
        case .pngEncodingFailed(let path):
            return "Could not encode PNG at \(path)."
        }
    }
}

extension FileManager {
    func copyItemReplacingExisting(at source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try copyItem(at: source, to: destination)
    }
}

do {
    if #available(macOS 13.0, *) {
        try await MainActor.run {
            try Renderer.run(arguments: CommandLine.arguments)
        }
    } else {
        fputs("PalmiIconRenderer requires macOS 13 or later.\n", stderr)
        exit(1)
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
