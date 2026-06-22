import Foundation

enum MultimodalImageRoutingDecision: String, Codable, Sendable {
    case primaryInlineImage
    case multimodalScannerTool
    case ocrFallback
    case unavailable

    static func resolve(
        hasImageAttachments: Bool,
        primaryHasInlineImage: Bool,
        multimodalScannerAvailable: Bool,
        canUseMultimodalScanner: Bool,
        canUseOCR: Bool
    ) -> MultimodalImageRoutingDecision? {
        guard hasImageAttachments else { return nil }
        if primaryHasInlineImage {
            return .primaryInlineImage
        }
        if canUseMultimodalScanner, multimodalScannerAvailable {
            return .multimodalScannerTool
        }
        if canUseOCR {
            return .ocrFallback
        }
        return .unavailable
    }
}
