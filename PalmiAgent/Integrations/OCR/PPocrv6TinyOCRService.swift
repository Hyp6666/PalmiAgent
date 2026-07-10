import Foundation

struct TinyOCRModelAsset: Codable, Hashable, Sendable {
    let role: String
    let modelName: String
    let relativePath: String
    let byteCount: Int64
    let sha256: String
}

struct TinyOCRLine: Codable, Sendable {
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

struct TinyOCRResult: Codable, Sendable {
    let sourcePath: String
    let textPath: String
    let jsonPath: String
    let engine: String
    let modelName: String
    let imageWidth: Int
    let imageHeight: Int
    let lines: [TinyOCRLine]
    let modelAssets: [TinyOCRModelAsset]

    var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

@MainActor
final class PPocrv6TinyOCRService {
    private let workspaceManager: WorkspaceManager
    private let fileManager: FileManager
    private let recognitionWorker: OCRRecognitionWorker

    init(
        workspaceManager: WorkspaceManager,
        fileManager: FileManager = .default,
        recognitionWorker: OCRRecognitionWorker = OCRRecognitionWorker()
    ) {
        self.workspaceManager = workspaceManager
        self.fileManager = fileManager
        self.recognitionWorker = recognitionWorker
    }

    func recognizeImageText(
        at relativePath: String,
        outputDirectory: String?,
        recognitionLanguages: [String],
        usesLanguageCorrection: Bool
    ) async throws -> TinyOCRResult {
        let imageURL = try workspaceManager.url(for: relativePath)
        guard fileManager.fileExists(atPath: imageURL.path) else {
            throw AppError.invalidState("图片不存在：\(relativePath)")
        }

        let modelAssets = try resolveModelAssets()
        let recognition = try await recognitionWorker.recognize(
            imageURL: imageURL,
            recognitionLanguages: recognitionLanguages,
            usesLanguageCorrection: usesLanguageCorrection
        )
        let outputBaseDirectory = normalizedOutputDirectory(
            requested: outputDirectory,
            sourcePath: relativePath
        )
        let outputBaseName = sanitizedOutputBaseName(from: relativePath)
        let textPath = "\(outputBaseDirectory)/\(outputBaseName).ocr.txt"
        let jsonPath = "\(outputBaseDirectory)/\(outputBaseName).ocr.json"

        let result = TinyOCRResult(
            sourcePath: relativePath,
            textPath: textPath,
            jsonPath: jsonPath,
            engine: "pp-ocrv6-tiny-bundled-assets+vision-runtime",
            modelName: "PP-OCRv6_tiny",
            imageWidth: recognition.imageWidth,
            imageHeight: recognition.imageHeight,
            lines: recognition.lines,
            modelAssets: modelAssets
        )

        _ = try workspaceManager.writeText(result.plainText, to: textPath)
        _ = try workspaceManager.writeText(try encodeResult(result), to: jsonPath)
        return result
    }

    private func resolveModelAssets() throws -> [TinyOCRModelAsset] {
        let assets = [
            try resolveModelAsset(
                role: "text_detection",
                modelName: "PP-OCRv6_tiny_det",
                relativePath: "det/inference.onnx",
                sha256: "193bab7a04fca699a6c82e6abb5b81bdb28177f0abd4062552b04908dafb19f8"
            ),
            try resolveModelAsset(
                role: "text_recognition",
                modelName: "PP-OCRv6_tiny_rec",
                relativePath: "rec/inference.onnx",
                sha256: "9ef676d6ed3c88256a2d92c640c44f25b0c40947e111b14b8be8f594091563e6"
            )
        ]
        return assets
    }

    private func resolveModelAsset(
        role: String,
        modelName: String,
        relativePath: String,
        sha256: String
    ) throws -> TinyOCRModelAsset {
        let url = modelBundleURL()?.appendingPathComponent(relativePath, isDirectory: false)
        guard let url,
              fileManager.fileExists(atPath: url.path) else {
            throw AppError.invalidState("缺少 PP-OCRv6 Tiny 模型资源：\(relativePath)")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return TinyOCRModelAsset(
            role: role,
            modelName: modelName,
            relativePath: relativePath,
            byteCount: Int64(values.fileSize ?? 0),
            sha256: sha256
        )
    }

    private func modelBundleURL() -> URL? {
        if let url = Bundle.main.url(
            forResource: "PP-OCRv6-tiny",
            withExtension: "bundle"
        ) {
            return url
        }
        return Bundle.main.resourceURL?
            .appendingPathComponent("Resources/OCR/PP-OCRv6-tiny.bundle", isDirectory: true)
    }

    private func normalizedOutputDirectory(
        requested: String?,
        sourcePath: String
    ) -> String {
        if let requested {
            let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let range = sourcePath.range(of: "/original/"),
           sourcePath.hasPrefix(".files/uploads/") {
            return String(sourcePath[..<range.lowerBound]) + "/extracted"
        }
        return ".files/ocr"
    }

    private func sanitizedOutputBaseName(from relativePath: String) -> String {
        let filename = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let candidate = filename.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return candidate.isEmpty ? "image" : candidate
    }

    private func encodeResult(_ result: TinyOCRResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppError.operationFailed("OCR JSON 编码失败。")
        }
        return text
    }
}
