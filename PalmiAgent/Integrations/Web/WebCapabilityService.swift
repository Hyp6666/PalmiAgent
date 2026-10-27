import Foundation

nonisolated struct WebAdapterDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let operation: WebOperation
    let executionKind: WebExecutionKind
    let resultCapabilities: [WebResultCapability]
    /// 预设连接的默认端点（按 templateID 给出成对的 base 与相对路径或完整地址）。
    let defaultEndpoints: [String: WebEndpoint]
    let note: String

    var requiresModel: Bool { executionKind == .modelServerTool }
}

nonisolated enum WebAdapterCatalog {
    static let all: [WebAdapterDescriptor] = [
        .init(id: WebAdapterID.deepSeekSearch, title: "DeepSeek 搜索 API", operation: .search, executionKind: .independentHTTP,
              resultCapabilities: [.structuredSearchHits],
              defaultEndpoints: ["deepseek": .apiBasePlusRelativePath(base: "https://api.deepseek.com", relativePath: "v1/tools/search")],
              note: "独立工具接口，不需要模型"),
        .init(id: WebAdapterID.deepSeekFetch, title: "DeepSeek 网页读取 API", operation: .fetch, executionKind: .independentHTTP,
              resultCapabilities: [.extractedPageText],
              defaultEndpoints: ["deepseek": .apiBasePlusRelativePath(base: "https://api.deepseek.com", relativePath: "v1/tools/fetch")],
              note: "返回提取的 Markdown，不是 DOM 或快照"),
        .init(id: WebAdapterID.deepSeekResponsesSearch, title: "DeepSeek Responses 联网", operation: .search, executionKind: .modelServerTool,
              resultCapabilities: [.searchSynthesisOnly, .structuredSearchHits],
              defaultEndpoints: ["deepseek": .explicitURL("https://api.deepseek.com/responses")],
              note: "需要支持服务端 web_search 的模型"),
        .init(id: WebAdapterID.openAIResponsesSearch, title: "OpenAI Responses 联网", operation: .search, executionKind: .modelServerTool,
              resultCapabilities: [.structuredSearchHits, .searchSynthesisOnly],
              defaultEndpoints: ["openai": .apiBasePlusRelativePath(base: "https://api.openai.com/v1", relativePath: "responses")],
              note: "web_search 服务端工具"),
        .init(id: WebAdapterID.anthropicSearch, title: "Anthropic 联网搜索", operation: .search, executionKind: .modelServerTool,
              resultCapabilities: [.structuredSearchHits, .searchSynthesisOnly],
              defaultEndpoints: ["anthropic": .apiBasePlusRelativePath(base: "https://api.anthropic.com/v1", relativePath: "messages")],
              note: "web_search 服务端工具"),
        .init(id: WebAdapterID.anthropicFetch, title: "Anthropic 网页抓取", operation: .fetch, executionKind: .modelServerTool,
              resultCapabilities: [.extractedPageText, .documentBytes],
              defaultEndpoints: ["anthropic": .apiBasePlusRelativePath(base: "https://api.anthropic.com/v1", relativePath: "messages")],
              note: "web_fetch 服务端工具，与搜索分别验证"),
        .init(id: WebAdapterID.qwenChatSearch, title: "百炼 Chat 联网（enable_search）", operation: .search, executionKind: .modelServerTool,
              resultCapabilities: [.searchSynthesisOnly],
              defaultEndpoints: ["bailian": .explicitURL("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")],
              note: "只返回模型结论，不保证结构化来源"),
        .init(id: WebAdapterID.qwenResponsesSearch, title: "百炼 Responses 联网", operation: .search, executionKind: .modelServerTool,
              resultCapabilities: [.structuredSearchHits, .searchSynthesisOnly], defaultEndpoints: [:],
              note: "需填写 Workspace 与区域的完整 Responses 地址"),
        .init(id: WebAdapterID.qwenResponsesExtractor, title: "百炼网页提取", operation: .fetch, executionKind: .modelServerTool,
              resultCapabilities: [.extractedEvidence], defaultEndpoints: [:],
              note: "目标导向的提取内容，不保证全文"),
        .init(id: WebAdapterID.kimiSearchBasic, title: "Kimi 搜索", operation: .search, executionKind: .independentHTTP,
              resultCapabilities: [.structuredSearchHits],
              defaultEndpoints: ["kimi": .apiBasePlusRelativePath(base: "https://api.moonshot.cn/v1", relativePath: "tools/search")],
              note: "独立工具接口，不需要模型"),
        .init(id: WebAdapterID.kimiSearchPro, title: "Kimi 搜索 Pro", operation: .search, executionKind: .independentHTTP,
              resultCapabilities: [.structuredSearchHits],
              defaultEndpoints: ["kimi": .apiBasePlusRelativePath(base: "https://api.moonshot.cn/v1", relativePath: "tools/search_pro")],
              note: "独立收费档位，不会自动升级"),
        .init(id: WebAdapterID.kimiFetch, title: "Kimi 网页读取", operation: .fetch, executionKind: .independentHTTP,
              resultCapabilities: [.extractedPageText],
              defaultEndpoints: ["kimi": .apiBasePlusRelativePath(base: "https://api.moonshot.cn/v1", relativePath: "tools/fetch")],
              note: "返回 Markdown，图片为链接或占位"),
        .init(id: WebAdapterID.zhipuSearch, title: "智谱网络搜索", operation: .search, executionKind: .independentHTTP,
              resultCapabilities: [.structuredSearchHits],
              defaultEndpoints: ["zhipu": .apiBasePlusRelativePath(base: "https://open.bigmodel.cn/api/paas/v4", relativePath: "web_search")],
              note: "独立工具接口，不需要模型"),
        .init(id: WebAdapterID.zhipuReader, title: "智谱网页阅读", operation: .fetch, executionKind: .independentHTTP,
              resultCapabilities: [.extractedPageText],
              defaultEndpoints: ["zhipu": .apiBasePlusRelativePath(base: "https://open.bigmodel.cn/api/paas/v4", relativePath: "reader")],
              note: "REST 接口；Coding Plan 的 MCP Reader 是另一产品"),
        .init(id: WebAdapterID.geminiSearch, title: "Gemini Google 搜索", operation: .search, executionKind: .modelServerTool,
              resultCapabilities: [.structuredSearchHits, .searchSynthesisOnly], defaultEndpoints: [:],
              note: "使用连接中明确声明的原生 generateContent 端点"),
        .init(id: WebAdapterID.geminiURLContext, title: "Gemini 网页上下文", operation: .fetch, executionKind: .modelServerTool,
              resultCapabilities: [.modelURLAnalysis], defaultEndpoints: [:],
              note: "返回模型分析与读取状态，不保证全文"),
        .init(id: WebAdapterID.xaiResponsesSearch, title: "xAI 联网搜索", operation: .search, executionKind: .modelServerTool,
              resultCapabilities: [.structuredSearchHits, .searchSynthesisOnly],
              defaultEndpoints: ["xai": .apiBasePlusRelativePath(base: "https://api.x.ai/v1", relativePath: "responses")],
              note: "web_search 服务端工具"),
        .init(id: WebAdapterID.arkResponsesSearch, title: "火山方舟联网搜索", operation: .search, executionKind: .modelServerTool,
              resultCapabilities: [.structuredSearchHits, .searchSynthesisOnly],
              defaultEndpoints: ["ark": .explicitURL("https://ark.cn-beijing.volces.com/api/v3/responses")],
              note: "默认 search_engine 来源"),
        .init(id: WebAdapterID.baiduSearch, title: "百度千帆搜索", operation: .search, executionKind: .independentHTTP,
              resultCapabilities: [.structuredSearchHits],
              defaultEndpoints: ["baidu": .explicitURL("https://qianfan.baidubce.com/v2/ai_search/web_search")],
              note: "独立工具接口，standard 档位"),
        .init(id: WebAdapterID.genericResponsesSearch, title: "通用 Responses 联网", operation: .search, executionKind: .modelServerTool,
              resultCapabilities: [.searchSynthesisOnly], defaultEndpoints: [:],
              note: "只使用公共合同，能力需验证"),
        .init(id: WebAdapterID.genericMessagesSearch, title: "通用 Messages 联网", operation: .search, executionKind: .modelServerTool,
              resultCapabilities: [.searchSynthesisOnly], defaultEndpoints: [:],
              note: "只使用公共合同，能力需验证")
    ]

    static func descriptor(_ id: String) -> WebAdapterDescriptor? { all.first { $0.id == id } }

    static func adapters(for operation: WebOperation) -> [WebAdapterDescriptor] { all.filter { $0.operation == operation } }

    /// 某个模型可用的接口：预设来源对应的厂商接口，加上按模型协议适用的通用接口。需要手填地址的接口不在此列。
    static func adapters(for operation: WebOperation, model: ModelRecord, connection: ConnectionRecord) -> [WebAdapterDescriptor] {
        guard connection.chatGPTAccount == nil, !model.imageGenerationOnly else { return [] }
        let wireProtocol = model.wireProtocol(in: connection)
        return adapters(for: operation).filter { descriptor in
            if let template = connection.templateID, descriptor.defaultEndpoints[template] != nil { return true }
            switch descriptor.id {
            case WebAdapterID.geminiSearch, WebAdapterID.geminiURLContext:
                return connection.endpoints.geminiNativeBaseURL != nil
            case WebAdapterID.genericResponsesSearch:
                return connection.endpoints.responsesURL != nil && (wireProtocol == .responses || wireProtocol == .automatic)
            case WebAdapterID.genericMessagesSearch:
                return connection.endpoints.messagesURL != nil && wireProtocol == .anthropicMessages
            default:
                return false
            }
        }
    }

    /// 预设连接或模型服务端工具的默认端点：预设给出成对地址；服务端工具复用连接的对应协议端点。
    static func suggestedEndpoint(for descriptor: WebAdapterDescriptor, connection: ConnectionRecord) -> WebEndpoint? {
        if let template = connection.templateID, let endpoint = descriptor.defaultEndpoints[template] { return endpoint }
        switch descriptor.id {
        case WebAdapterID.geminiSearch, WebAdapterID.geminiURLContext:
            return connection.endpoints.geminiNativeBaseURL.map(WebEndpoint.explicitURL)
        case WebAdapterID.anthropicSearch, WebAdapterID.anthropicFetch, WebAdapterID.genericMessagesSearch:
            return connection.endpoints.messagesURL.map(WebEndpoint.explicitURL)
        case WebAdapterID.qwenChatSearch:
            return connection.endpoints.chatCompletionsURL.map(WebEndpoint.explicitURL)
        default:
            guard descriptor.executionKind == .modelServerTool else { return nil }
            return connection.endpoints.responsesURL.map(WebEndpoint.explicitURL)
        }
    }
}

/// 解析后冻结的具体后端。普通工具入口、浏览器网页入口、参数规范化、权限审核和执行日志消费同一个结果。
nonisolated enum ResolvedWebBackend: Sendable, Equatable {
    case local
    case adapter(bindingID: UUID, adapterID: String, connectionID: UUID, modelRecordID: UUID?, endpoint: URL, label: String)

    var displayDescription: String {
        switch self {
        case .local: "本机"
        case .adapter(_, let adapterID, _, _, let endpoint, let label):
            "\(label)（\(WebAdapterCatalog.descriptor(adapterID)?.title ?? adapterID)，\(endpoint.host ?? endpoint.absoluteString)）"
        }
    }

    var normalizedArguments: [String: Any] {
        switch self {
        case .local: ["backend": "local"]
        case .adapter(let bindingID, let adapterID, _, _, let endpoint, let label):
            ["backend": "cloud", "binding_id": bindingID.uuidString.lowercased(), "adapter": adapterID,
             "endpoint_host": endpoint.host ?? "", "binding": label]
        }
    }
}

@MainActor
final class WebCapabilityService {
    private let library: ModelLibraryStore
    private let session: URLSession

    init(library: ModelLibraryStore, session: URLSession = WebHTTP.session) {
        self.library = library
        self.session = session
    }

    /// 用户配置的默认绑定 → 具体后端；未配置时走本机。需要正文的操作不会选只提供模型分析的后端。
    func resolve(_ operation: WebOperation, requiring capability: WebResultCapability? = nil) throws -> ResolvedWebBackend {
        let web = library.state.web
        let id = operation == .search ? web.defaultSearchBindingID : web.defaultFetchBindingID
        guard let id else { return .local }
        guard let binding = web.binding(id) else { throw WebCapabilityError.bindingMissing(id) }
        guard let connection = library.state.connection(binding.connectionID) else { throw WebCapabilityError.bindingMissing(id) }
        if let capability, let descriptor = WebAdapterCatalog.descriptor(binding.adapterID),
           !descriptor.resultCapabilities.contains(capability) {
            throw WebCapabilityError.resultCapabilityMismatch(capability)
        }
        if binding.executionKind == .modelServerTool {
            guard let modelID = binding.modelRecordID, let model = library.state.model(modelID) else { throw WebCapabilityError.modelRequired }
            guard model.connectionID == binding.connectionID else { throw WebCapabilityError.connectionMismatch }
        }
        return .adapter(
            bindingID: binding.id, adapterID: binding.adapterID, connectionID: connection.id,
            modelRecordID: binding.modelRecordID, endpoint: try binding.endpoint.resolvedURL(),
            label: binding.userLabel ?? connection.displayName
        )
    }

    func options(for bindingID: UUID) -> [String: JSONRuntimeValue] {
        library.state.web.binding(bindingID)?.options ?? [:]
    }

    func execute(
        _ backend: ResolvedWebBackend,
        request: WebAdapterRequest,
        verification: Bool = false,
        timeLimit: TimeInterval? = nil
    ) async -> WebOperationResult {
        guard case .adapter(let bindingID, let adapterID, let connectionID, let modelRecordID, let endpoint, _) = backend else {
            return WebIndependentAdapters.failure(.search, adapter: "local", error: WebAdapterError(kind: .unsupportedCapability, message: "本机后端不经由适配器执行"))
        }
        guard let connection = library.state.connection(connectionID) else {
            return WebIndependentAdapters.failure(.search, adapter: adapterID, error: WebAdapterError(kind: .invalidInput, message: "连接已不存在"))
        }
        let apiKey: String?
        switch connection.authenticationKind {
        case .apiKey:
            switch library.credentialRead(for: connection) {
            case .present(let key): apiKey = key
            case .notFound:
                return WebIndependentAdapters.failure(.search, adapter: adapterID, error: WebAdapterError(kind: .authentication, message: "连接「\(connection.displayName)」没有保存 API Key"))
            case .temporarilyUnavailable:
                return WebIndependentAdapters.failure(.search, adapter: adapterID, error: WebAdapterError(kind: .authentication, message: "凭据暂时不可读，请解锁设备后重试"))
            case .failed(let status):
                return WebIndependentAdapters.failure(.search, adapter: adapterID, error: WebAdapterError(kind: .authentication, message: "无法读取凭据（\(status)）"))
            }
        case .none:
            apiKey = nil
        case .chatGPTOAuth:
            // OAuth 令牌不能自动当作通用 API key；能力不明时保持未验证。
            return WebIndependentAdapters.failure(.search, adapter: adapterID, error: WebAdapterError(kind: .unsupportedCapability, message: "Codex OAuth 连接不能用于该网页工具接口"))
        }
        var context = WebAdapterContext(
            endpoint: endpoint, apiKey: apiKey,
            modelID: modelRecordID.flatMap { library.state.model($0)?.providerModelID },
            extraHeaders: connection.endpoints.extraHeaders, session: session,
            budget: verification ? .verification() : .production(userLimit: timeLimit),
            isVerification: verification
        )
        let descriptor = WebAdapterCatalog.descriptor(adapterID)
        var result: WebOperationResult
        if descriptor?.executionKind == .independentHTTP {
            result = await WebIndependentAdapters.execute(adapterID: adapterID, request: request, context: &context)
        } else {
            result = await WebModelToolAdapters.execute(adapterID: adapterID, request: request, context: &context)
        }
        result.bindingID = bindingID
        result.usage.httpRequests = max(result.usage.httpRequests, context.requestCounter.value)
        record(result, connection: connection, adapterID: adapterID, modelRecordID: modelRecordID, endpoint: endpoint, verification: verification)
        return result
    }

    /// 能力证据键：连接、有效端点、适配器、实际模型、认证主体与修订。只改显示名不失效。
    func evidenceKey(connection: ConnectionRecord, adapterID: String, modelRecordID: UUID?, endpoint: URL) -> String {
        [connection.id.uuidString, endpoint.absoluteString, adapterID,
         modelRecordID.flatMap { library.state.model($0)?.providerModelID } ?? "",
         connection.authenticationSubject, String(connection.endpointRevision), String(connection.credentialRevision)]
            .joined(separator: "|")
    }

    private func record(_ result: WebOperationResult, connection: ConnectionRecord, adapterID: String, modelRecordID: UUID?, endpoint: URL, verification: Bool) {
        guard let bindingID = result.bindingID else { return }
        let verificationState: WebCapabilityVerification
        switch (result.status, result.executionEvidence) {
        case (.completed, .typedDirectResponse), (.completed, .completedServerTool), (.completed, .metadataGrounding):
            verificationState = .verified
        case (.completedEmpty, .typedDirectResponse):
            verificationState = .verifiedEmpty
        case (_, .declaredOnly):
            verificationState = .unverified
        default:
            if result.errors.contains(where: { $0.kind == .unsupportedCapability && $0.message.contains("notInvoked") }) {
                verificationState = .notInvoked
            } else if result.errors.contains(where: { [.rateLimited, .serverError, .network, .timeout, .targetUnavailable, .targetPolicy].contains($0.kind) }) {
                verificationState = .failed
            } else if result.errors.contains(where: { $0.kind == .unsupportedCapability }) {
                verificationState = .unverified
            } else {
                verificationState = .failed
            }
        }
        // 只有非空可核查 URL 才能证明本次返回了可用来源；只有执行回执不能升级为结构化命中。
        var capabilities = result.resultCapabilities
        if result.hits.isEmpty { capabilities.removeAll { $0 == .structuredSearchHits } }
        let evidence = WebCapabilityEvidenceRecord(
            bindingID: bindingID,
            evidenceKey: evidenceKey(connection: connection, adapterID: adapterID, modelRecordID: modelRecordID, endpoint: endpoint),
            verification: verificationState,
            resultCapabilities: capabilities,
            observedAt: .now,
            httpStatus: result.httpStatus,
            requestID: result.requestID,
            note: (verification ? "检测：" : "运行：") + (result.errors.first?.localizedDescription ?? result.status.rawValue)
        )
        library.recordWebEvidence(evidence)
    }

    /// 用户明确触发的检测：只请求选定能力，用公开官方文档查询或公开小网页；默认一次请求，协议要求时最多一次续传。
    func verify(bindingID: UUID) async -> WebOperationResult {
        guard let binding = library.state.web.binding(bindingID),
              let connection = library.state.connection(binding.connectionID),
              let endpoint = try? binding.endpoint.resolvedURL() else {
            return WebIndependentAdapters.failure(.search, adapter: "unknown", error: WebAdapterError(kind: .invalidInput, message: "网页工具配置无效"))
        }
        let backend = ResolvedWebBackend.adapter(
            bindingID: binding.id, adapterID: binding.adapterID, connectionID: connection.id,
            modelRecordID: binding.modelRecordID, endpoint: endpoint, label: binding.userLabel ?? connection.displayName
        )
        let request = WebAdapterRequest(
            query: binding.operation == .search ? "Swift programming language official documentation" : nil,
            url: binding.operation == .fetch ? URL(string: "https://example.com/") : nil,
            count: 3, question: binding.operation == .fetch ? "这个页面的标题是什么？" : nil,
            options: binding.options
        )
        return await execute(backend, request: request, verification: true)
    }

    // MARK: 工具输出格式

    /// 结构化命中按完整条目输出（条目之间空行分隔，分页时不切半条）；服务商摘要与模型综合分别标注。
    static func formatSearch(_ result: WebOperationResult, query: String, backend: ResolvedWebBackend) -> String {
        var lines = [
            "查询：\(query)",
            "搜索后端：\(backend.displayDescription)",
            "状态：\(result.status.rawValue)；执行证据：\(result.executionEvidence.rawValue)；来源：\(result.sourceObservation.rawValue)"
        ]
        if let requestID = result.requestID { lines.append("请求 ID：\(requestID)") }
        for error in result.errors { lines.append("错误：\(error.localizedDescription)") }
        for note in result.notes { lines.append("说明：\(note)") }
        if let synthesis = result.assistantSynthesis?.trimmingCharacters(in: .whitespacesAndNewlines), !synthesis.isEmpty {
            lines.append("")
            lines.append("模型生成的结论（不是网页原文）：")
            lines.append(synthesis)
        }
        lines.append("")
        if result.hits.isEmpty {
            lines.append(result.sourceObservation == .confirmedEmpty ? "来源：服务明确返回 0 条结果。" : "来源：服务未暴露结构化来源。")
        } else {
            lines.append("来源（服务方排序）：")
        }
        let blocks = result.hits.enumerated().map { index, hit -> String in
            var block = ["[\(index + 1)] \(hit.title ?? hit.url.host ?? hit.url.absoluteString)", "URL：\(hit.url.absoluteString)"]
            if let label = hit.citationLabel { block.append("引用标记：\(label)") }
            if let site = hit.siteName { block.append("站点：\(site)") }
            if let date = hit.date { block.append("日期（\(hit.dateKind?.rawValue ?? "unspecified")）：\(date)") }
            if let snippet = hit.snippet { block.append("片段：\(snippet)") }
            if let summary = hit.providerSummary { block.append("服务商摘要（非全文）：\(summary)") }
            if let content = hit.content { block.append("服务商内容（\(hit.contentKind ?? "excerpt")，非网页全文）：\(content)") }
            return block.joined(separator: "\n")
        }
        return lines.joined(separator: "\n") + (blocks.isEmpty ? "" : "\n\n" + blocks.joined(separator: "\n\n"))
    }

    static func formatFetch(_ result: WebOperationResult, requested: [URL], backend: ResolvedWebBackend, start: Int, end: Int) -> String {
        var lines = [
            "抓取后端：\(backend.displayDescription)",
            "状态：\(result.status.rawValue)；执行证据：\(result.executionEvidence.rawValue)"
        ]
        for error in result.errors { lines.append("错误：\(error.localizedDescription)") }
        for note in result.notes { lines.append("说明：\(note)") }
        if result.pages.isEmpty, !requested.isEmpty {
            lines.append("请求网址：" + requested.map(\.absoluteString).joined(separator: ", "))
        }
        for page in result.pages {
            lines.append("")
            lines.append("请求网址：\(page.requestedURL.absoluteString)")
            if let returned = page.returnedURL { lines.append("服务返回网址：\(returned.absoluteString)") }
            if let title = page.title { lines.append("标题：\(title)") }
            lines.append("内容类型：\(page.format)\(page.limitedByService ? "（服务可能限制了内容长度）" : "")")
            if page.format == "model_analysis" || page.format == "evidence" {
                lines.append("注意：以下是服务端模型的阅读结论或提取证据，不是网页全文。")
            }
            let text = page.text ?? (page.documentData.map { "（\(page.mediaType ?? "二进制文档")，\($0.count) 字节，未以文本形式返回）" } ?? "")
            let characters = Array(text)
            let lower = min(max(0, start), characters.count)
            let upper = end < 0 ? characters.count : min(max(lower, end), characters.count)
            lines.append("范围：[\(lower), \(upper)) / \(characters.count) 字符")
            lines.append(String(characters[lower..<upper]))
        }
        return lines.joined(separator: "\n")
    }
}
