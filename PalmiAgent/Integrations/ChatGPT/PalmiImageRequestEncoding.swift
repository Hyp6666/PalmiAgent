import Foundation

/// 瞬时运输层输入。绝不编码进 prompts、Bionic 记录或开发面板。
struct PalmiPreparedReference: Sendable {
    let sourcePath: String
    let sourceSHA256: String
    let preparedSHA256: String
    let mimeType: String
    let bytes: Data
}

struct PalmiEncodedImageRequest: Sendable {
    let endpointPath: String
    let body: Data
}

nonisolated enum PalmiImageEncodingError: Error, Equatable {
    case invalidInput
    case tooManyReferences
    case invalidReference
    case referenceBudgetExceeded
    case requestBudgetExceeded
}

/// 已验证输入 → 当前 OAuth 兼容 JSON 的映射。不承担文件授权、内容解码或真伪检测；
/// 前置校验必须在调用前完成。
nonisolated enum PalmiImageRequestEncoding {
    static let perReferenceLimit = 8 * 1024 * 1024
    static let totalReferenceLimit = 16 * 1024 * 1024
    static let encodedRequestLimit = 24 * 1024 * 1024

    static func make(
        model: String,
        prompt: String,
        references: [PalmiPreparedReference]
    ) throws -> PalmiEncodedImageRequest {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PalmiImageEncodingError.invalidInput
        }
        guard references.count <= 3 else { throw PalmiImageEncodingError.tooManyReferences }
        var total = 0
        for reference in references {
            guard ["image/png", "image/jpeg", "image/webp"].contains(reference.mimeType),
                  !reference.bytes.isEmpty else { throw PalmiImageEncodingError.invalidReference }
            guard reference.bytes.count <= perReferenceLimit,
                  reference.bytes.count <= totalReferenceLimit - total else {
                throw PalmiImageEncodingError.referenceBudgetExceeded
            }
            total += reference.bytes.count
        }
        var object: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "n": 1,
            "size": "1024x1024",
            "output_format": "png",
            "stream": false
        ]
        let endpoint: String
        if references.isEmpty {
            endpoint = "images/generations"
        } else {
            endpoint = "images/edits"
            // 数组顺序与冻结参考清单相同；MIME 随准备数据一致。
            object["images"] = references.map { reference in
                ["image_url": "data:\(reference.mimeType);base64,\(reference.bytes.base64EncodedString())"]
            }
        }
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard body.count <= encodedRequestLimit else { throw PalmiImageEncodingError.requestBudgetExceeded }
        return PalmiEncodedImageRequest(endpointPath: endpoint, body: body)
    }
}
