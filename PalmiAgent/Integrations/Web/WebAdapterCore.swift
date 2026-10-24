import Foundation

// 联网能力的统一结果与证据。普通函数调用、厂商服务端工具和独立 HTTP 工具三种执行方式共用这一结果对象，
// 但各自的请求体、完成证据和费用约束分开实现。

nonisolated enum WebAdapterID {
    static let deepSeekSearch = "deepseek.tools.search.v1"
    static let deepSeekFetch = "deepseek.tools.fetch.v1"
    static let deepSeekResponsesSearch = "deepseek.responses.web_search"
    static let openAIResponsesSearch = "openai.responses.web_search"
    static let anthropicSearch = "anthropic.messages.web_search"
    static let anthropicFetch = "anthropic.messages.web_fetch"
    static let qwenChatSearch = "qwen.chat.enable_search"
    static let qwenResponsesSearch = "qwen.responses.web_search"
    static let qwenResponsesExtractor = "qwen.responses.web_extractor"
    static let kimiSearchBasic = "kimi.tools.search.basic"
    static let kimiSearchPro = "kimi.tools.search.pro"
    static let kimiFetch = "kimi.tools.fetch"
    static let zhipuSearch = "zhipu.web_search"
    static let zhipuReader = "zhipu.reader"
    static let geminiSearch = "gemini.generate_content.google_search"
    static let geminiURLContext = "gemini.generate_content.url_context"
    static let xaiResponsesSearch = "xai.responses.web_search"
    static let arkResponsesSearch = "ark.responses.web_search"
    static let baiduSearch = "baidu.qianfan.web_search"
    /// 旧远程搜索迁入的通用适配器：只用公共合同，保持未验证状态，不宣称原生厂商能力。
    static let genericResponsesSearch = "generic.responses.web_search"
    static let genericMessagesSearch = "generic.messages.web_search"
}

nonisolated enum WebOperationStatus: String, Codable, Sendable {
    case completed, completedEmpty, partial, pending, failed, cancelled, budgetExceeded
}

nonisolated enum WebExecutionEvidence: String, Codable, Sendable {
    case typedDirectResponse, completedServerTool, metadataGrounding, declaredOnly, none
}

nonisolated enum WebSourceObservation: String, Codable, Sendable {
    case present, confirmedEmpty, unobservable
}

nonisolated enum WebDateKind: String, Codable, Sendable {
    case published, updated, providerUnspecified, retrieved
}

nonisolated struct WebSearchHit: Codable, Sendable, Equatable {
    var url: URL
    var title: String?
    var snippet: String?
    /// 服务商自带的摘要，不是网页全文。
    var providerSummary: String?
    /// 服务商返回的正文或相关片段（按 contentKind 标注），不冒充全文。
    var content: String?
    var contentKind: String?
    var siteName: String?
    var citationLabel: String?
    var date: String?
    var dateKind: WebDateKind?
    var score: Double?
    var sourceType: String?
}

nonisolated struct WebFetchedContent: Codable, Sendable, Equatable {
    var requestedURL: URL
    /// 只有服务确实返回时才记录；不凭空声明 canonical URL。
    var returnedURL: URL?
    var title: String?
    var text: String?
    /// markdown / text / pdf / model_analysis / evidence
    var format: String
    var documentData: Data?
    var mediaType: String?
    var retrievalStatus: String?
    var limitedByService: Bool
    var retrievedAt: String?
}

nonisolated struct WebUsage: Codable, Sendable, Equatable {
    var modelInputTokens: Int?
    var modelOutputTokens: Int?
    var serverToolCalls: Int?
    var httpRequests: Int = 0
    var raw: [String: JSONRuntimeValue] = [:]
}

nonisolated enum WebAdapterErrorKind: String, Codable, Sendable {
    case authentication, quotaOrBilling, accountPermission, targetPolicy, endpointNotFound, targetUnavailable
    case methodNotAllowed, rateLimited, serverError, network, timeout, badRequest, requestTooLarge
    case unsupportedCapability, protocolError, parseError, cancelled, budgetExceeded, emptyContent
    case invalidInput, unexpectedClientTool
}

nonisolated struct WebAdapterError: Error, LocalizedError, Codable, Sendable, Equatable {
    var kind: WebAdapterErrorKind
    var message: String
    var httpStatus: Int?
    var code: String?
    var requestID: String?

    var errorDescription: String? {
        var text = message
        if let httpStatus { text += "（HTTP \(httpStatus)）" }
        if let code { text += "［\(code)］" }
        return text
    }

    /// 错误分类：解析结构化错误代码，不靠随意匹配英文句子；HTTP 状态与业务码是不同维度。
    static func classify(status: Int, code: String?, message: String, requestID: String? = nil, targetContext: Bool = false) -> WebAdapterError {
        let kind: WebAdapterErrorKind
        switch status {
        case 400: kind = .badRequest
        case 401: kind = .authentication
        case 402: kind = .quotaOrBilling
        case 403: kind = targetContext ? .targetPolicy : .accountPermission
        case 404: kind = targetContext ? .targetUnavailable : .endpointNotFound
        case 405: kind = .methodNotAllowed
        case 408: kind = .timeout
        case 413: kind = .requestTooLarge
        case 422: kind = .badRequest
        case 429: kind = .rateLimited
        case 500...599: kind = .serverError
        default: kind = .protocolError
        }
        return WebAdapterError(kind: kind, message: message.isEmpty ? "请求失败" : message, httpStatus: status, code: code, requestID: requestID)
    }
}

nonisolated struct WebOperationResult: Sendable, Equatable {
    var operation: WebOperation
    var adapterID: String
    var bindingID: UUID?
    var status: WebOperationStatus
    var executionEvidence: WebExecutionEvidence
    var sourceObservation: WebSourceObservation
    var hits: [WebSearchHit] = []
    var pages: [WebFetchedContent] = []
    /// 模型生成的结论单列，不与来源正文混在一起。
    var assistantSynthesis: String?
    var httpStatus: Int?
    var requestID: String?
    var protocolTerminalState: String?
    var callIDs: [String] = []
    var usage = WebUsage()
    var errors: [WebAdapterError] = []
    var resultCapabilities: [WebResultCapability] = []
    var notes: [String] = []
}

/// 一次网页操作的总预算：默认总时限不超过 90 秒、最多三次协议续传；自动重试另行计数，默认不重试结果未知的 POST。
nonisolated struct WebOperationBudget: Sendable {
    var deadline: Date
    var maximumContinuations: Int
    var continuationsUsed = 0

    static func production(now: Date = .now, userLimit: TimeInterval? = nil) -> WebOperationBudget {
        WebOperationBudget(deadline: now.addingTimeInterval(min(90, userLimit ?? 90)), maximumContinuations: 3)
    }

    static func verification(now: Date = .now) -> WebOperationBudget {
        WebOperationBudget(deadline: now.addingTimeInterval(60), maximumContinuations: 1)
    }

    var remaining: TimeInterval { deadline.timeIntervalSinceNow }

    mutating func admitContinuation() throws {
        guard continuationsUsed < maximumContinuations, remaining > 1 else {
            throw WebAdapterError(kind: .budgetExceeded, message: "网页操作超出时限或续传预算")
        }
        continuationsUsed += 1
    }
}

nonisolated struct WebAdapterRequest: Sendable {
    var query: String?
    var url: URL?
    var count: Int
    var question: String?
    var options: [String: JSONRuntimeValue]
}

nonisolated enum WebAuthenticationStyle: Sendable, Equatable {
    case bearer
    case anthropic
    case googleAPIKey
    case none
}

nonisolated struct WebAdapterContext: Sendable {
    let endpoint: URL
    let apiKey: String?
    let modelID: String?
    let extraHeaders: [String: String]
    let session: URLSession
    var budget: WebOperationBudget
    let isVerification: Bool
    /// 本次操作实际发出的 HTTP 请求数（续传与重试都计入）。
    let requestCounter = WebCounterBox()
}

/// 跨 origin 重定向不转发认证，避免把端点凭据送往抓取目标或第三方。
nonisolated final class WebCapabilityRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let authenticationHeaders = ["Authorization", "x-api-key", "x-goog-api-key", "api-key"]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let target = request.url else {
            completionHandler(request)
            return
        }
        let sameOrigin = original.scheme == target.scheme && original.host == target.host && original.port == target.port
        guard !sameOrigin else { completionHandler(request); return }
        var stripped = request
        for header in Self.authenticationHeaders { stripped.setValue(nil, forHTTPHeaderField: header) }
        completionHandler(stripped)
    }
}

nonisolated enum WebHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration, delegate: WebCapabilityRedirectGuard(), delegateQueue: nil)
    }()

    static func headers(style: WebAuthenticationStyle, apiKey: String?, extra: [String: String]) -> [String: String] {
        var headers = extra
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return headers }
        switch style {
        case .bearer: headers["Authorization"] = "Bearer \(key)"
        case .anthropic:
            headers["x-api-key"] = key
            headers["anthropic-version"] = headers["anthropic-version"] ?? "2023-06-01"
        case .googleAPIKey: headers["x-goog-api-key"] = key
        case .none: break
        }
        return headers
    }

    /// 单次 POST，不自动重试（结果未知的 POST 可能已经收费）。
    static func post(
        _ url: URL,
        body: [String: JSONRuntimeValue],
        headers: [String: String],
        context: inout WebAdapterContext
    ) async throws -> (Data, HTTPURLResponse) {
        guard context.budget.remaining > 1 else { throw WebAdapterError(kind: .budgetExceeded, message: "网页操作超出时限") }
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: max(5, min(90, context.budget.remaining)))
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(body)
        context.requestCounter.value += 1
        do {
            let (data, response) = try await context.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WebAdapterError(kind: .protocolError, message: "返回了非 HTTP 响应")
            }
            return (data, http)
        } catch is CancellationError {
            throw WebAdapterError(kind: .cancelled, message: "已取消")
        } catch let error as URLError where error.code == .cancelled {
            throw WebAdapterError(kind: .cancelled, message: "已取消")
        } catch let error as URLError where error.code == .timedOut {
            throw WebAdapterError(kind: .timeout, message: "请求超时")
        } catch let error as WebAdapterError {
            throw error
        } catch {
            throw WebAdapterError(kind: .network, message: error.localizedDescription)
        }
    }

    static func decodeObject(_ data: Data) -> [String: JSONRuntimeValue]? {
        guard let value = try? JSONDecoder().decode(JSONRuntimeValue.self, from: data), case .object(let object) = value else { return nil }
        return object
    }

    static func requestID(_ response: HTTPURLResponse) -> String? {
        for name in ["x-request-id", "request-id", "x-msh-track-id", "x-acs-request-id", "x-tt-logid"] {
            if let value = response.value(forHTTPHeaderField: name), !value.isEmpty { return value }
        }
        return nil
    }

    /// 解析各家错误外形：error 对象、error 字符串、顶层 message/code（code 可数字或字符串）。
    static func structuredError(_ object: [String: JSONRuntimeValue]?) -> (message: String, code: String?)? {
        guard let object else { return nil }
        if case .object(let error)? = object["error"] {
            let message = error["message"]?.stringValue ?? error["msg"]?.stringValue ?? ""
            let code = error["code"].flatMap(Self.codeString) ?? error["type"]?.stringValue ?? error["status"]?.stringValue
            return (message, code)
        }
        if case .string(let message)? = object["error"] { return (message, object["code"].flatMap(Self.codeString)) }
        if let code = object["code"].flatMap(Self.codeString), code != "0", code != "200" {
            return (object["message"]?.stringValue ?? object["msg"]?.stringValue ?? "", code)
        }
        return nil
    }

    static func codeString(_ value: JSONRuntimeValue) -> String? {
        switch value {
        case .string(let text): text
        case .number(let number): number.rounded() == number ? String(Int(number)) : String(number)
        default: nil
        }
    }
}

/// 在一次操作内累计 HTTP 请求数的计数器。
nonisolated final class WebCounterBox: @unchecked Sendable { var value = 0 }

extension JSONRuntimeValue {
    nonisolated var objectValueOrNil: [String: JSONRuntimeValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    nonisolated var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    nonisolated var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

nonisolated enum WebURLValidation {
    /// 目标 URL：HTTP/HTTPS、有 host、无内嵌用户名密码，长度受限。
    static func target(_ raw: String, maximumLength: Int = 8_192) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumLength,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              let url = components.url else {
            throw WebAdapterError(kind: .invalidInput, message: "目标网址无效：\(trimmed.prefix(200))")
        }
        return url
    }

    static func sourceURL(_ value: JSONRuntimeValue?) -> URL? {
        guard let text = value?.stringValue, let url = try? target(text) else { return nil }
        return url
    }
}
