import Foundation

// 网页搜索与抓取作为独立可配置能力。搜索和抓取分别绑定；本地实现以 nil 默认表示，不需要模型。

nonisolated enum WebOperation: String, Codable, CaseIterable, Sendable, Hashable {
    case search
    case fetch
}

nonisolated enum WebExecutionKind: String, Codable, Sendable, Hashable {
    /// 独立 HTTP 工具接口，直接返回搜索或网页数据，不需要模型。
    case independentHTTP
    /// 一次模型生成过程中由厂商执行的服务端工具，必须有实际模型。
    case modelServerTool
}

/// 结果能力：找到 URL、相关摘要、读过网页、返回完整正文、返回快照互不等价。
nonisolated enum WebResultCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case structuredSearchHits
    case searchSynthesisOnly
    case extractedPageText
    case extractedEvidence
    case documentBytes
    case modelURLAnalysis
    case fullSnapshot
}

/// 端点只有两种明确形式：最终地址，或明确的 API base 加相对路径。
nonisolated enum WebEndpoint: Codable, Hashable, Sendable {
    case explicitURL(String)
    case apiBasePlusRelativePath(base: String, relativePath: String)

    func resolvedURL() throws -> URL {
        switch self {
        case .explicitURL(let raw):
            return try WebEndpointValidator.validated(raw)
        case .apiBasePlusRelativePath(let base, let relativePath):
            let baseURL = try WebEndpointValidator.validated(base)
            guard !relativePath.hasPrefix("/") else {
                // 以斜杠开头的相对路径会覆盖 base 的已有前缀，明确拒绝。
                throw WebCapabilityError.invalidEndpoint("相对路径不能以 / 开头：\(relativePath)")
            }
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw WebCapabilityError.invalidEndpoint(base)
            }
            var path = components.path
            if !path.hasSuffix("/") { path += "/" }
            let relative = URLComponents(string: relativePath)
            components.path = path + (relative?.path ?? relativePath)
            if let extraItems = relative?.queryItems, !extraItems.isEmpty {
                components.queryItems = (components.queryItems ?? []) + extraItems
            }
            guard let url = components.url else { throw WebCapabilityError.invalidEndpoint(base) }
            return url
        }
    }

    var displayValue: String {
        switch self {
        case .explicitURL(let raw): ModelLibraryURLDisplay.safeDisplay(raw)
        case .apiBasePlusRelativePath(let base, let relative): ModelLibraryURLDisplay.safeDisplay(base) + " + " + relative
        }
    }
}

nonisolated enum WebEndpointValidator {
    static func validated(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host?.isEmpty == false else {
            throw WebCapabilityError.invalidEndpoint(trimmed)
        }
        guard components.user == nil, components.password == nil else {
            throw WebCapabilityError.invalidEndpoint("地址中不允许包含用户名或密码。")
        }
        guard let url = components.url else { throw WebCapabilityError.invalidEndpoint(trimmed) }
        return url
    }
}

nonisolated struct WebCapabilityBinding: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var operation: WebOperation
    var adapterID: String
    var executionKind: WebExecutionKind
    var connectionID: UUID
    /// 独立 HTTP 工具可以为空；服务端工具必须引用同一连接上的模型。
    var modelRecordID: UUID?
    var endpoint: WebEndpoint
    var options: [String: JSONRuntimeValue]
    var revision: Int
    var userLabel: String?
    var createdAt: Date
    var updatedAt: Date
}

nonisolated enum WebCapabilityVerification: String, Codable, Sendable, Hashable {
    case verified
    case verifiedEmpty
    case unverified
    case notInvoked
    case unsupported
    case failed
}

nonisolated struct WebCapabilityEvidenceRecord: Codable, Hashable, Sendable {
    let bindingID: UUID
    let evidenceKey: String
    let verification: WebCapabilityVerification
    let resultCapabilities: [WebResultCapability]
    let observedAt: Date
    let httpStatus: Int?
    let requestID: String?
    let note: String
}

nonisolated struct WebCapabilityConfiguration: Codable, Hashable, Sendable {
    var bindings: [WebCapabilityBinding] = []
    /// nil 表示使用本机实现。
    var defaultSearchBindingID: UUID?
    var defaultFetchBindingID: UUID?
    /// 上次成功证据与本次运行状态分开保存。
    var lastSuccessfulEvidence: [UUID: WebCapabilityEvidenceRecord] = [:]
    var lastRunEvidence: [UUID: WebCapabilityEvidenceRecord] = [:]

    func binding(_ id: UUID?) -> WebCapabilityBinding? {
        guard let id else { return nil }
        return bindings.first { $0.id == id }
    }
}

nonisolated enum WebCapabilityError: Error, LocalizedError, Equatable, Sendable {
    case invalidEndpoint(String)
    case notConfigured(WebOperation)
    case bindingMissing(UUID)
    case connectionMismatch
    case modelRequired
    case credentialUnavailable(String)
    case invalidQuery(String)
    case resultCapabilityMismatch(WebResultCapability)
    case budgetExceeded
    case unexpectedClientTool(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let value): "网页工具地址无效：\(value)"
        case .notConfigured(let operation): operation == .search ? "未配置网页搜索服务。" : "未配置网页抓取服务。"
        case .bindingMissing: "网页工具配置已不存在。"
        case .connectionMismatch: "服务端工具的模型与绑定的连接不一致，已拒绝发送凭据。"
        case .modelRequired: "服务端网页工具需要选择一个模型。"
        case .credentialUnavailable(let message): message
        case .invalidQuery(let message): message
        case .resultCapabilityMismatch(let capability): "所选网页服务不能提供需要的结果类型：\(capability.rawValue)。"
        case .budgetExceeded: "网页操作超出时限或续传预算。"
        case .unexpectedClientTool(let name): "网页服务意外要求执行客户端工具 \(name)，已拒绝执行。"
        }
    }
}
