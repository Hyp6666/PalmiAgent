import Foundation

/// 独立 HTTP 搜索与抓取：不需要模型，直接返回搜索或网页数据。按各家正式成功 schema 判定，合法空数组记 completedEmpty。
nonisolated enum WebIndependentAdapters {
    // MARK: 通用

    static func failure(
        _ operation: WebOperation, adapter: String, error: WebAdapterError, status: Int? = nil, requestID: String? = nil
    ) -> WebOperationResult {
        var result = WebOperationResult(
            operation: operation, adapterID: adapter, bindingID: nil,
            status: error.kind == .cancelled ? .cancelled : (error.kind == .budgetExceeded ? .budgetExceeded : .failed),
            executionEvidence: .none, sourceObservation: .unobservable
        )
        result.httpStatus = status ?? error.httpStatus
        result.requestID = requestID ?? error.requestID
        result.errors = [error]
        return result
    }

    /// HTTP 非 2xx 或 200 内嵌错误。认证失败可能没有 JSON body，不能覆盖原 HTTP 错误。
    static func httpError(_ data: Data, _ response: HTTPURLResponse, targetContext: Bool) -> WebAdapterError? {
        let object = WebHTTP.decodeObject(data)
        let structured = WebHTTP.structuredError(object)
        if !(200..<300).contains(response.statusCode) {
            return WebAdapterError.classify(
                status: response.statusCode, code: structured?.code,
                message: structured?.message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                requestID: WebHTTP.requestID(response), targetContext: targetContext
            )
        }
        if let structured, object?["error"] != nil {
            return WebAdapterError(kind: .protocolError, message: structured.message, httpStatus: response.statusCode,
                                   code: structured.code, requestID: WebHTTP.requestID(response))
        }
        return nil
    }

    static func searchResult(adapter: String, hits: [WebSearchHit], response: HTTPURLResponse, requestID: String?, notes: [String] = []) -> WebOperationResult {
        var result = WebOperationResult(
            operation: .search, adapterID: adapter, bindingID: nil,
            status: hits.isEmpty ? .completedEmpty : .completed,
            executionEvidence: .typedDirectResponse,
            sourceObservation: hits.isEmpty ? .confirmedEmpty : .present
        )
        result.hits = hits
        result.httpStatus = response.statusCode
        result.requestID = requestID ?? WebHTTP.requestID(response)
        result.resultCapabilities = [.structuredSearchHits]
        result.notes = notes
        result.usage.httpRequests = 1
        return result
    }

    static func string(_ object: [String: JSONRuntimeValue], _ key: String) -> String? {
        guard let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    // MARK: DeepSeek

    static func deepSeekSearchBody(_ request: WebAdapterRequest) throws -> [String: JSONRuntimeValue] {
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (1...128).contains(query.unicodeScalars.count) else {
            throw WebAdapterError(kind: .invalidInput, message: "DeepSeek 搜索的 query 需为 1 到 128 个字符且不能全为空白")
        }
        var body: [String: JSONRuntimeValue] = [
            "query": .string(query),
            "count": .number(Double(min(50, max(1, request.count)))),
            "need_content": .bool(request.options["need_content"]?.boolValue ?? false)
        ]
        if let question = request.question?.trimmingCharacters(in: .whitespacesAndNewlines), (1...128).contains(question.unicodeScalars.count) {
            body["ori_question"] = .string(question)
        }
        if let localization = request.options["localization"]?.stringValue { body["localization"] = .string(localization) }
        return body
    }

    static func parseDeepSeekSearch(_ data: Data, _ response: HTTPURLResponse) -> WebOperationResult {
        if let error = httpError(data, response, targetContext: false) {
            return failure(.search, adapter: WebAdapterID.deepSeekSearch, error: error, status: response.statusCode)
        }
        guard let object = WebHTTP.decodeObject(data), let rows = object["results"]?.arrayValue else {
            return failure(.search, adapter: WebAdapterID.deepSeekSearch,
                           error: WebAdapterError(kind: .parseError, message: "DeepSeek 搜索回包缺少 results"), status: response.statusCode)
        }
        let hits = rows.compactMap { row -> WebSearchHit? in
            guard let item = row.objectValueOrNil, let url = WebURLValidation.sourceURL(item["url"]) else { return nil }
            return WebSearchHit(
                url: url, title: string(item, "title"), snippet: string(item, "snippet"),
                providerSummary: string(item, "summary"), content: string(item, "content"),
                contentKind: string(item, "content") == nil ? nil : "provider_content",
                siteName: string(item, "site_name"), citationLabel: nil,
                date: string(item, "date"), dateKind: string(item, "date") == nil ? nil : .providerUnspecified,
                score: item["rerank_score"]?.doubleValue, sourceType: "web"
            )
        }
        return searchResult(adapter: WebAdapterID.deepSeekSearch, hits: hits, response: response, requestID: nil)
    }

    static func parseDeepSeekFetch(_ data: Data, _ response: HTTPURLResponse, requested: URL) -> WebOperationResult {
        // 404 在此 API 可表示目标不可用、站点策略、类型不支持或没有正文，不判为 endpoint 不存在。
        if let error = httpError(data, response, targetContext: true) {
            return failure(.fetch, adapter: WebAdapterID.deepSeekFetch, error: error, status: response.statusCode)
        }
        guard let object = WebHTTP.decodeObject(data) else {
            return failure(.fetch, adapter: WebAdapterID.deepSeekFetch, error: WebAdapterError(kind: .parseError, message: "DeepSeek 抓取回包无法解析"))
        }
        return fetchResult(adapter: WebAdapterID.deepSeekFetch, requested: requested, returned: nil,
                           title: string(object, "title"), text: object["content"]?.stringValue, format: "markdown",
                           response: response, capability: .extractedPageText)
    }

    static func fetchResult(
        adapter: String, requested: URL, returned: URL?, title: String?, text: String?, format: String,
        response: HTTPURLResponse, capability: WebResultCapability, extra: [String] = []
    ) -> WebOperationResult {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            var result = failure(.fetch, adapter: adapter, error: WebAdapterError(kind: .emptyContent, message: "服务未返回可提取的正文"),
                                 status: response.statusCode, requestID: WebHTTP.requestID(response))
            result.executionEvidence = .typedDirectResponse
            return result
        }
        var result = WebOperationResult(
            operation: .fetch, adapterID: adapter, bindingID: nil, status: .completed,
            executionEvidence: .typedDirectResponse, sourceObservation: .present
        )
        result.pages = [WebFetchedContent(
            requestedURL: requested, returnedURL: returned, title: title, text: text, format: format,
            documentData: nil, mediaType: "text/markdown", retrievalStatus: "ok", limitedByService: false, retrievedAt: nil
        )]
        result.httpStatus = response.statusCode
        result.requestID = WebHTTP.requestID(response)
        result.resultCapabilities = [capability]
        result.notes = extra
        result.usage.httpRequests = 1
        return result
    }

    // MARK: Kimi

    static func kimiSearchBody(_ request: WebAdapterRequest, pro: Bool) throws -> [String: JSONRuntimeValue] {
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { throw WebAdapterError(kind: .invalidInput, message: "Kimi 搜索的 text_query 不能为空") }
        var body: [String: JSONRuntimeValue] = [
            "text_query": .string(query),
            "limit": .number(Double(min(20, max(1, request.count)))),
            "timeout_seconds": .number(Double(min(60, max(1, Int(request.options["timeout_seconds"]?.doubleValue ?? 10)))))
        ]
        if pro {
            if let sites = request.options["sites"]?.arrayValue?.compactMap(\.stringValue), !sites.isEmpty {
                guard sites.count <= 5 else { throw WebAdapterError(kind: .invalidInput, message: "Kimi Pro 搜索最多 5 个站点") }
                body["sites"] = .array(sites.map(JSONRuntimeValue.string))
            }
            if let window = request.options["time_window"]?.objectValueOrNil {
                let start = window["start"]?.stringValue, end = window["end"]?.stringValue
                for value in [start, end].compactMap({ $0 }) where value.range(of: #"^\d{4}(-\d{2}(-\d{2})?)?$"#, options: .regularExpression) == nil {
                    throw WebAdapterError(kind: .invalidInput, message: "time_window 只支持年、年月或年月日：\(value)")
                }
                if let start, let end, start > end {
                    throw WebAdapterError(kind: .invalidInput, message: "time_window 的 start 不能晚于 end")
                }
                body["time_window"] = .object(window)
            }
        } else {
            // include_content 只属于 Basic 合同，不复制给 Pro。
            body["include_content"] = .bool(request.options["include_content"]?.boolValue ?? false)
        }
        return body
    }

    static func kimiError(_ data: Data, _ response: HTTPURLResponse, targetContext: Bool) -> WebAdapterError? {
        guard let error = httpError(data, response, targetContext: targetContext) else { return nil }
        var classified = error
        if let code = error.code {
            if code == "security_risk" { classified.kind = .targetPolicy }
            if code == "markdown_not_found" { classified.kind = .emptyContent }
        }
        classified.requestID = response.value(forHTTPHeaderField: "X-Msh-Track-Id") ?? classified.requestID
        return classified
    }

    static func parseKimiSearch(_ data: Data, _ response: HTTPURLResponse, pro: Bool) -> WebOperationResult {
        let adapter = pro ? WebAdapterID.kimiSearchPro : WebAdapterID.kimiSearchBasic
        if let error = kimiError(data, response, targetContext: false) {
            return failure(.search, adapter: adapter, error: error, status: response.statusCode)
        }
        guard let object = WebHTTP.decodeObject(data), let rows = object["search_results"]?.arrayValue else {
            return failure(.search, adapter: adapter, error: WebAdapterError(kind: .parseError, message: "Kimi 搜索回包缺少 search_results"))
        }
        let hits = rows.compactMap { row -> WebSearchHit? in
            guard let item = row.objectValueOrNil, let url = WebURLValidation.sourceURL(item["url"]) else { return nil }
            let chunks = item["chunks"]?.arrayValue?.compactMap { $0.objectValueOrNil?["text"]?.stringValue } ?? []
            let content = pro ? (chunks.isEmpty ? nil : chunks.joined(separator: "\n\n")) : string(item, "text")
            return WebSearchHit(
                url: url, title: string(item, "title"), snippet: string(item, "snippet"), providerSummary: nil,
                content: content, contentKind: content == nil ? nil : (pro ? "relevant_chunks" : "provider_text"),
                siteName: string(item, "site_name"), citationLabel: nil,
                date: string(item, "date"), dateKind: string(item, "date") == nil ? nil : .providerUnspecified,
                score: item["chunks"]?.arrayValue?.first?.objectValueOrNil?["score"]?.doubleValue,
                sourceType: string(item, "mime") ?? "web"
            )
        }
        var result = searchResult(adapter: adapter, hits: hits, response: response,
                                  requestID: response.value(forHTTPHeaderField: "X-Msh-Track-Id"))
        if let chat = response.value(forHTTPHeaderField: "X-Msh-Chat-Id") { result.notes.append("chat_id=\(chat)") }
        return result
    }

    static func parseKimiFetch(_ data: Data, _ response: HTTPURLResponse, requested: URL) -> WebOperationResult {
        if let error = kimiError(data, response, targetContext: true) {
            return failure(.fetch, adapter: WebAdapterID.kimiFetch, error: error, status: response.statusCode)
        }
        guard let object = WebHTTP.decodeObject(data) else {
            return failure(.fetch, adapter: WebAdapterID.kimiFetch, error: WebAdapterError(kind: .parseError, message: "Kimi 抓取回包无法解析"))
        }
        // 图片是链接或占位，不是图像二进制。
        return fetchResult(adapter: WebAdapterID.kimiFetch, requested: requested,
                           returned: WebURLValidation.sourceURL(object["url"]), title: string(object, "title"),
                           text: object["markdown"]?.stringValue, format: "markdown", response: response,
                           capability: .extractedPageText)
    }

    // MARK: 智谱

    static let zhipuEngines: Set<String> = ["search_std", "search_pro", "search_pro_sogou", "search_pro_quark"]

    static func zhipuSearchBody(_ request: WebAdapterRequest) throws -> [String: JSONRuntimeValue] {
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (1...70).contains(query.count) else { throw WebAdapterError(kind: .invalidInput, message: "智谱搜索的 search_query 需为 1 到 70 个字符") }
        let engine = request.options["search_engine"]?.stringValue ?? "search_std"
        guard zhipuEngines.contains(engine) else { throw WebAdapterError(kind: .invalidInput, message: "未知的智谱搜索引擎：\(engine)") }
        var count = min(50, max(1, request.count))
        if engine == "search_pro_sogou" { count = min(50, max(10, Int((Double(count) / 10).rounded(.up)) * 10)) }
        return [
            "search_engine": .string(engine), "search_query": .string(query), "search_intent": .bool(false),
            "count": .number(Double(count)), "content_size": .string(request.options["content_size"]?.stringValue ?? "medium")
        ]
    }

    static func parseZhipuSearch(_ data: Data, _ response: HTTPURLResponse) -> WebOperationResult {
        if let error = httpError(data, response, targetContext: false) {
            return failure(.search, adapter: WebAdapterID.zhipuSearch, error: error, status: response.statusCode)
        }
        guard let object = WebHTTP.decodeObject(data) else {
            return failure(.search, adapter: WebAdapterID.zhipuSearch, error: WebAdapterError(kind: .parseError, message: "智谱搜索回包无法解析"))
        }
        let rows = object["search_result"]?.arrayValue ?? []
        let hits = rows.compactMap { row -> WebSearchHit? in
            guard let item = row.objectValueOrNil, let url = WebURLValidation.sourceURL(item["link"]) else { return nil }
            return WebSearchHit(
                url: url, title: string(item, "title"), snippet: nil, providerSummary: nil,
                content: string(item, "content"), contentKind: string(item, "content") == nil ? nil : "provider_excerpt",
                siteName: string(item, "media"), citationLabel: string(item, "refer"),
                date: string(item, "publish_date"), dateKind: string(item, "publish_date") == nil ? nil : .published,
                score: nil, sourceType: "web"
            )
        }
        var notes: [String] = []
        if hits.isEmpty, object["search_intent"] != nil { notes.append("服务只返回了意图分析，没有实际搜索结果") }
        guard object["search_result"] != nil || object["search_intent"] != nil else {
            return failure(.search, adapter: WebAdapterID.zhipuSearch, error: WebAdapterError(kind: .parseError, message: "智谱搜索回包缺少 search_result"))
        }
        return searchResult(adapter: WebAdapterID.zhipuSearch, hits: hits, response: response,
                            requestID: object["request_id"]?.stringValue ?? object["id"]?.stringValue, notes: notes)
    }

    static func parseZhipuReader(_ data: Data, _ response: HTTPURLResponse, requested: URL) -> WebOperationResult {
        if let error = httpError(data, response, targetContext: true) {
            return failure(.fetch, adapter: WebAdapterID.zhipuReader, error: error, status: response.statusCode)
        }
        guard let object = WebHTTP.decodeObject(data), let reader = object["reader_result"]?.objectValueOrNil else {
            return failure(.fetch, adapter: WebAdapterID.zhipuReader, error: WebAdapterError(kind: .parseError, message: "智谱 Reader 回包缺少 reader_result"))
        }
        return fetchResult(adapter: WebAdapterID.zhipuReader, requested: requested, returned: WebURLValidation.sourceURL(reader["url"]),
                           title: string(reader, "title"), text: reader["content"]?.stringValue, format: "markdown",
                           response: response, capability: .extractedPageText)
    }

    // MARK: 百度千帆

    /// 查询上限 72 个计数单位：ASCII 记 1、非 ASCII 记 2；超出时不截断，返回 invalidQuery。
    static func baiduQueryUnits(_ query: String) -> Int {
        query.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
    }

    static func baiduSearchBody(_ request: WebAdapterRequest) throws -> [String: JSONRuntimeValue] {
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty, baiduQueryUnits(query) <= 72 else {
            throw WebAdapterError(kind: .invalidInput, message: "百度搜索查询超过 72 个计数单位（中文按 2 计），请缩短后重试")
        }
        let edition = request.options["edition"]?.stringValue ?? "standard"
        guard ["standard", "turbo", "pro"].contains(edition) else { throw WebAdapterError(kind: .invalidInput, message: "未知的 edition：\(edition)") }
        return [
            "messages": .array([.object(["role": .string("user"), "content": .string(query)])]),
            "search_source": .string("baidu_search_v2"),
            "edition": .string(edition),
            "resource_type_filter": .array([.object(["type": .string("web"), "top_k": .number(Double(min(50, max(1, request.count))))])]),
            "query_policy": .object(["enable_rewrite": .bool(false)])
        ]
    }

    static func parseBaiduSearch(_ data: Data, _ response: HTTPURLResponse) -> WebOperationResult {
        let object = WebHTTP.decodeObject(data)
        let requestID = object?["request_id"]?.stringValue ?? object?["requestId"]?.stringValue ?? WebHTTP.requestID(response)
        if let code = object?["code"].flatMap(WebHTTP.codeString), code != "0" {
            var error = WebAdapterError(kind: code == "216003" ? .authentication : .protocolError,
                                        message: object?["message"]?.stringValue ?? "百度搜索返回错误",
                                        httpStatus: response.statusCode, code: code, requestID: requestID)
            if !(200..<300).contains(response.statusCode), code != "216003" {
                error.kind = WebAdapterError.classify(status: response.statusCode, code: code, message: error.message).kind
            }
            return failure(.search, adapter: WebAdapterID.baiduSearch, error: error, status: response.statusCode, requestID: requestID)
        }
        if let error = httpError(data, response, targetContext: false) {
            return failure(.search, adapter: WebAdapterID.baiduSearch, error: error, status: response.statusCode, requestID: requestID)
        }
        guard let rows = object?["references"]?.arrayValue else {
            return failure(.search, adapter: WebAdapterID.baiduSearch, error: WebAdapterError(kind: .parseError, message: "百度搜索回包缺少 references"))
        }
        let hits = rows.compactMap { row -> WebSearchHit? in
            guard let item = row.objectValueOrNil else { return nil }
            let type = item["type"]?.stringValue
            guard type == nil || type == "web", let url = WebURLValidation.sourceURL(item["url"]) else { return nil }
            return WebSearchHit(
                url: url, title: string(item, "title"), snippet: string(item, "snippet"), providerSummary: nil,
                content: string(item, "content"), contentKind: string(item, "content") == nil ? nil : "provider_excerpt",
                siteName: nil, citationLabel: string(item, "id"),
                date: string(item, "date"), dateKind: string(item, "date") == nil ? nil : .providerUnspecified,
                score: nil, sourceType: "web"
            )
        }
        if !rows.isEmpty && hits.isEmpty {
            return failure(.search, adapter: WebAdapterID.baiduSearch,
                           error: WebAdapterError(kind: .parseError, message: "返回了结果但没有可解析的网页来源（schemaMismatch）"),
                           status: response.statusCode, requestID: requestID)
        }
        return searchResult(adapter: WebAdapterID.baiduSearch, hits: hits, response: response, requestID: requestID)
    }

    // MARK: 执行

    static func execute(adapterID: String, request: WebAdapterRequest, context: inout WebAdapterContext) async -> WebOperationResult {
        let operation: WebOperation = [WebAdapterID.deepSeekFetch, WebAdapterID.kimiFetch, WebAdapterID.zhipuReader].contains(adapterID) ? .fetch : .search
        do {
            let headers = WebHTTP.headers(style: .bearer, apiKey: context.apiKey, extra: context.extraHeaders)
            switch adapterID {
            case WebAdapterID.deepSeekSearch:
                let (data, response) = try await WebHTTP.post(context.endpoint, body: try deepSeekSearchBody(request), headers: headers, context: &context)
                return parseDeepSeekSearch(data, response)
            case WebAdapterID.deepSeekFetch:
                let target = try target(request)
                let (data, response) = try await WebHTTP.post(context.endpoint, body: ["url": .string(target.absoluteString)], headers: headers, context: &context)
                return parseDeepSeekFetch(data, response, requested: target)
            case WebAdapterID.kimiSearchBasic, WebAdapterID.kimiSearchPro:
                let pro = adapterID == WebAdapterID.kimiSearchPro
                let (data, response) = try await WebHTTP.post(context.endpoint, body: try kimiSearchBody(request, pro: pro), headers: headers, context: &context)
                return parseKimiSearch(data, response, pro: pro)
            case WebAdapterID.kimiFetch:
                let target = try target(request)
                let (data, response) = try await WebHTTP.post(context.endpoint, body: ["url": .string(target.absoluteString)], headers: headers, context: &context)
                return parseKimiFetch(data, response, requested: target)
            case WebAdapterID.zhipuSearch:
                let (data, response) = try await WebHTTP.post(context.endpoint, body: try zhipuSearchBody(request), headers: headers, context: &context)
                return parseZhipuSearch(data, response)
            case WebAdapterID.zhipuReader:
                let target = try target(request)
                let body: [String: JSONRuntimeValue] = [
                    "url": .string(target.absoluteString), "return_format": .string("markdown"),
                    "timeout": .number(20), "no_cache": .bool(false)
                ]
                let (data, response) = try await WebHTTP.post(context.endpoint, body: body, headers: headers, context: &context)
                return parseZhipuReader(data, response, requested: target)
            case WebAdapterID.baiduSearch:
                let (data, response) = try await WebHTTP.post(context.endpoint, body: try baiduSearchBody(request), headers: headers, context: &context)
                return parseBaiduSearch(data, response)
            default:
                return failure(operation, adapter: adapterID, error: WebAdapterError(kind: .unsupportedCapability, message: "未知的独立网页适配器"))
            }
        } catch let error as WebAdapterError {
            return failure(operation, adapter: adapterID, error: error)
        } catch {
            return failure(operation, adapter: adapterID, error: WebAdapterError(kind: .network, message: error.localizedDescription))
        }
    }

    static func target(_ request: WebAdapterRequest) throws -> URL {
        guard let url = request.url else { throw WebAdapterError(kind: .invalidInput, message: "缺少目标网址") }
        return try WebURLValidation.target(url.absoluteString)
    }
}
