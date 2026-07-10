import Foundation
import UIKit
import Vision

struct OCRRecognitionOutput: Sendable {
    let imageWidth: Int
    let imageHeight: Int
    let lines: [TinyOCRLine]
}

actor OCRRecognitionWorker {
    func recognize(
        imageURL: URL,
        recognitionLanguages: [String],
        usesLanguageCorrection: Bool
    ) throws -> OCRRecognitionOutput {
        try Task.checkCancellation()
        let imageData = try Data(contentsOf: imageURL)
        guard let image = UIImage(data: imageData),
              let cgImage = image.cgImage else {
            throw AppError.invalidState("目标文件不是可识别的图片：\(imageURL.lastPathComponent)")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        request.recognitionLanguages = recognitionLanguages.isEmpty
            ? ["zh-Hans", "en-US"]
            : recognitionLanguages

        try Task.checkCancellation()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        try Task.checkCancellation()

        let lines = (request.results ?? []).compactMap { observation -> TinyOCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TinyOCRLine(
                text: text,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox
            )
        }
        return OCRRecognitionOutput(
            imageWidth: cgImage.width,
            imageHeight: cgImage.height,
            lines: lines
        )
    }
}
