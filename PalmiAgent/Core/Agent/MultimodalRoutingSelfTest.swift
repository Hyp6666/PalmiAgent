import Foundation
import ImageIO

#if DEBUG
enum MultimodalRoutingSelfTest {
    static let launchArgument = "--palmi-run-multimodal-routing-self-test"
    private static let outputFilename = "multimodal-routing-self-test.json"
    private static let sourceImageFilename = "multimodal-routing-source-image.jpg"

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }

        let rows = [
            row(
                name: "deepseek-primary-qwen-scanner",
                primaryModel: "DeepSeek V4 Pro",
                multimodalModel: "qwen3.5-9b",
                primaryHasInlineImage: false,
                multimodalScannerAvailable: true
            ),
            row(
                name: "qwen-primary-qwen-scanner",
                primaryModel: "qwen3.5-9b",
                multimodalModel: "qwen3.5-9b",
                primaryHasInlineImage: true,
                multimodalScannerAvailable: true
            ),
            row(
                name: "deepseek-primary-no-scanner",
                primaryModel: "DeepSeek V4 Pro",
                multimodalModel: "none",
                primaryHasInlineImage: false,
                multimodalScannerAvailable: false
            )
        ]

        let report = Report(
            generatedAt: Date(),
            mainLoopModelRole: APIModelRole.reasoningModel.rawValue,
            multimodalScanToolModelRole: APIModelRole.multimodalModel.rawValue,
            testImage: imageEvidence(),
            rows: rows
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            try data.write(to: outputURL(), options: [.atomic])
            if let json = String(data: data, encoding: .utf8) {
                print("PALMI_MULTIMODAL_ROUTING_SELF_TEST \(json)")
            }
        } catch {
            print("PALMI_MULTIMODAL_ROUTING_SELF_TEST_ERROR \(error.localizedDescription)")
        }
    }

    private static func row(
        name: String,
        primaryModel: String,
        multimodalModel: String,
        primaryHasInlineImage: Bool,
        multimodalScannerAvailable: Bool
    ) -> Row {
        let decision = MultimodalImageRoutingDecision.resolve(
            hasImageAttachments: true,
            primaryHasInlineImage: primaryHasInlineImage,
            multimodalScannerAvailable: multimodalScannerAvailable,
            canUseMultimodalScanner: true,
            canUseOCR: true
        ) ?? .unavailable

        return Row(
            name: name,
            primaryModel: primaryModel,
            multimodalModel: multimodalModel,
            primaryHasInlineImage: primaryHasInlineImage,
            multimodalScannerAvailable: multimodalScannerAvailable,
            decision: decision.rawValue
        )
    }

    private static func outputURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appendingPathComponent(outputFilename, isDirectory: false)
    }

    private static func imageEvidence() -> ImageEvidence? {
        do {
            let url = try documentsDirectory().appendingPathComponent(sourceImageFilename, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            var pixelWidth: Int?
            var pixelHeight: Int?
            var imageReadable = false

            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                imageReadable = true
                pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
                pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            }
            let inlineDataURL = MultimodalInlineImageEncoder.dataURL(at: url)

            return ImageEvidence(
                filename: sourceImageFilename,
                byteCount: values.fileSize ?? 0,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                imageReadable: imageReadable,
                inlineDataURLPrefix: inlineDataURL.map { String($0.prefix(23)) },
                inlineDataURLCharacterCount: inlineDataURL?.count
            )
        } catch {
            return nil
        }
    }

    private static func documentsDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    struct Report: Codable {
        let generatedAt: Date
        let mainLoopModelRole: String
        let multimodalScanToolModelRole: String
        let testImage: ImageEvidence?
        let rows: [Row]
    }

    struct ImageEvidence: Codable {
        let filename: String
        let byteCount: Int
        let pixelWidth: Int?
        let pixelHeight: Int?
        let imageReadable: Bool
        let inlineDataURLPrefix: String?
        let inlineDataURLCharacterCount: Int?
    }

    struct Row: Codable {
        let name: String
        let primaryModel: String
        let multimodalModel: String
        let primaryHasInlineImage: Bool
        let multimodalScannerAvailable: Bool
        let decision: String
    }
}
#endif
