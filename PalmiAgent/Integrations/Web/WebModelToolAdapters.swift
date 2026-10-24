import Foundation

/// 厂商服务端工具：一次模型生成过程中由厂商执行。HTTP 2xx、回复 OK、回显 tools、正文自称搜索、普通链接、
/// 单独的开始事件或只有 server_tool_use，都不足以证明工具执行；按各适配器协议专用的完成回执判定。
nonisolated enum WebModelToolAdapters {
    static let searchPrompt = "请使用联网搜索工具查找下面的问题，给出简短事实结论，并保留所用来源。\n\n问题："
    static let fetchPrompt = "请读取下面的网页，提取与问题相关的内容并给出来源。\n\n网址："

    // MARK: Responses 家族

    static func responsesBody(adapterID: String, model: String, request: WebAdapterRequest, verification: Bool) throws -> [String: JSONRuntimeValue] {
        let query = request.query ?? ""
        var body: [String: JSONRuntimeValue] = ["model": .string(model), "stream": .bool(false)]
        switch adapterID {
        case WebAdapterID.openAIResponsesSearch:
            let toolType = request.options["tool_type"]?.stringValue ?? "web_search"
            body["input"] = .string(searchPrompt + query)
            body["tools"] = .array([.object(["type": .string(toolType)])])
            body["tool_choice"] = .string("required")
            body["include"] = .array([.string("web_search_call.action.sources")])
            body["max_tool_calls"] = .number(verification ? 1 : Double(Int(request.options["max_tool_calls"]?.doubleValue ?? 3)))
            body["max_output_tokens"] = .number(2048)
        case WebAdapterID.deepSeekResponsesSearch:
            // 该兼容接口会静默忽略许多 OpenAI 字段，不复用带全部 OpenAI 字段的模板。
            body["input"] = .string(searchPrompt + query)
            body["tools"] = .array([.object(["type": .string("web_search")])])
            body["tool_choice"] = .string("required")
            body["max_output_tokens"] = .number(2048)
        case WebAdapterID.xaiResponsesSearch:
            var tool: [String: JSONRuntimeValue] = ["type": .string("web_search")]
            if let filters = request.options["filters"]?.objectValueOrNil {
                let allowed = filters["allowed_domains"]?.arrayValue ?? []
                let excluded = filters["excluded_domains"]?.arrayValue ?? []
                guard allowed.isEmpty || excluded.isEmpty, allowed.count <= 5, excluded.count <= 5 else {
                    throw WebAdapterError(kind: .invalidInput, message: "xAI 域名过滤 allowed 与 excluded 互斥，各最多 5 个")
                }
                tool["filters"] = .object(filters)
            }
            body["input"] = .string(searchPrompt + query)
            body["tools"] = .array([.object(tool)])
            body["tool_choice"] = .string("required")
            body["include"] = .array([.string("web_search_call.action.sources")])
            body["max_turns"] = .number(2)
            body["parallel_tool_calls"] = .bool(false)
            body["max_output_tokens"] = .number(1024)
            body["store"] = .bool(false)
        case WebAdapterID.arkResponsesSearch:
            let sources = request.options["sources"]?.arrayValue?.compactMap(\.stringValue) ?? ["search_engine"]
            if sources.contains("doubao") && sources.count > 1 {
                throw WebAdapterError(kind: .invalidInput, message: "方舟的 doubao 来源只能单独使用")
            }
            // 工具请求不发送 caching；store 是另一个字段。
            body["input"] = .string(searchPrompt + query)
            body["tools"] = .array([.object([
                "type": .string("web_search"), "sources": .array(sources.map(JSONRuntimeValue.string)),
                "limit": .number(Double(min(10, max(1, request.count)))), "max_keyword": .number(1)
            ])])
            body["tool_choice"] = .object(["type": .string("web_search")])
            body["max_tool_calls"] = .number(1)
            body["max_output_tokens"] = .number(2048)
            body["store"] = .bool(false)
        case WebAdapterID.qwenResponsesSearch:
            body["input"] = .string(searchPrompt + query)
            body["tools"] = .array([.object(["type": .string("web_search")])])
            body["tool_choice"] = .string("required")
            body["max_output_tokens"] = .number(2048)
        case WebAdapterID.qwenResponsesExtractor:
            // web_extractor 必须与 web_search 同时声明，启用思考与流式；两个工具时不发 required。
            body["input"] = .string(fetchPrompt + (request.url?.absoluteString ?? "") + (request.question.map { "\n问题：" + $0 } ?? ""))
            body["tools"] = .array([.object(["type": .string("web_search")]), .object(["type": .string("web_extractor")])])
            body["enable_thinking"] = .bool(true)
            body["max_output_tokens"] = .number(4096)
            body["stream"] = .bool(true)
        case WebAdapterID.genericResponsesSearch:
            // 旧远程搜索的原协议语义：只声明 web_search 工具。
            body["input"] = .string("Use the available web_search server tool to search the web for the following query. You must actually call web_search. Return a concise factual answer and preserve the sources used.\n\nQuery: " + query)
            body["tools"] = .array([.object(["type": .string("web_search")])])
        default:
            throw WebAdapterError(kind: .unsupportedCapability, message: "未知的 Responses 网页适配器")
        }
        return body
    }

    struct ResponsesParse {
        var rootStatus: String?
        var incompleteReason: String?
        var searchCalls: [(id: String, status: String?, hasAction: Bool)] = []
        var extractorCalls: [(id: String, status: String?, urls: [String], output: String?)] = []
        var unexpectedClientTool: String?
        var text = ""
        var hits: [WebSearchHit] = []
        var citedURLs: Set<String> = []
        var usageSearchCalls: Int?
        var usage = WebUsage()
    }

    static func parseResponsesRoot(_ root: [String: JSONRuntimeValue], adapterID: String) -> ResponsesParse {
        var parse = ResponsesParse()
        parse.rootStatus = root["status"]?.stringValue
        parse.incompleteReason = root["incomplete_details"]?.objectValueOrNil?["reason"]?.stringValue
        var byURL: [String: Int] = [:]
        func addHit(url: URL, title: String?, label: String?, siteName: String? = nil, summary: String? = nil, date: String? = nil) {
            let key = url.absoluteString
            if let index = byURL[key] {
                if parse.hits[index].title == nil { parse.hits[index].title = title }
                if parse.hits[index].citationLabel == nil { parse.hits[index].citationLabel = label }
                return
            }
            byURL[key] = parse.hits.count
            parse.hits.append(WebSearchHit(
                url: url, title: title, snippet: nil, providerSummary: summary, content: nil, contentKind: nil,
                siteName: siteName, citationLabel: label, date: date,
                dateKind: date == nil ? nil : .providerUnspecified, score: nil, sourceType: "web"
            ))
        }
        for item in root["output"]?.arrayValue ?? [] {
            guard let object = item.objectValueOrNil else { continue }
            switch object["type"]?.stringValue {
            case "web_search_call":
                let action = object["action"]?.objectValueOrNil
                parse.searchCalls.append((object["id"]?.stringValue ?? "", object["status"]?.stringValue, action != nil))
                for source in action?["sources"]?.arrayValue ?? [] {
                    guard let source = source.objectValueOrNil, let url = WebURLValidation.sourceURL(source["url"]) else { continue }
                    addHit(url: url, title: source["title"]?.stringValue, label: nil)
                }
            case "web_extractor_call":
                parse.extractorCalls.append((
                    object["id"]?.stringValue ?? "", object["status"]?.stringValue,
                    object["urls"]?.arrayValue?.compactMap(\.stringValue) ?? [], object["output"]?.stringValue
                ))
            case "function_call", "shell_call", "local_shell_call", "computer_call", "custom_tool_call":
                parse.unexpectedClientTool = object["name"]?.stringValue ?? object["type"]?.stringValue
            case "message":
                for block in object["content"]?.arrayValue ?? [] {
                    guard let block = block.objectValueOrNil else { continue }
                    if block["type"]?.stringValue == "output_text", let text = block["text"]?.stringValue {
                        parse.text += (parse.text.isEmpty ? "" : "\n") + text
                    }
                    for annotation in block["annotations"]?.arrayValue ?? [] {
                        guard let annotation = annotation.objectValueOrNil,
                              annotation["type"]?.stringValue == "url_citation" || annotation["url"] != nil,
                              let url = WebURLValidation.sourceURL(annotation["url"]) else { continue }
                        parse.citedURLs.insert(url.absoluteString)
                        let rawTitle = annotation["title"]?.stringValue
                        // xAI 的 url_citation.title 是引用标签（例如 "1"），不是网页标题。
                        let isXAI = adapterID == WebAdapterID.xaiResponsesSearch
                        addHit(
                            url: url,
                            title: isXAI ? nil : rawTitle,
                            label: isXAI ? rawTitle : nil,
                            siteName: annotation["site_name"]?.stringValue,
                            summary: annotation["summary"]?.stringValue,
                            date: annotation["publish_time"]?.stringValue
                        )
                    }
                }
            default:
                break
            }
        }
        if case .object(let usage)? = root["usage"] {
            parse.usage.raw = usage
            parse.usage.modelInputTokens = usage["input_tokens"]?.doubleValue.map { Int($0) }
            parse.usage.modelOutputTokens = usage["output_tokens"]?.doubleValue.map { Int($0) }
            if let details = usage["server_side_tool_usage_details"]?.objectValueOrNil {
                parse.usageSearchCalls = details["web_search_calls"]?.doubleValue.map { Int($0) }
            }
            if let toolUsage = usage["tool_usage"]?.objectValueOrNil {
                parse.usageSearchCalls = toolUsage["web_search"]?.doubleValue.map { Int($0) }
            }
            // 百炼：usage.x_tools 与 x_details[].plugins 可能重复表达，只取一处计数。
            if let xTools = usage["x_tools"]?.objectValueOrNil ?? root["x_tools"]?.objectValueOrNil,
               let search = xTools["web_search"]?.objectValueOrNil {
                parse.usageSearchCalls = search["count"]?.doubleValue.map { Int($0) }
            } else if let details = usage["x_details"]?.arrayValue {
                let count = details.compactMap { $0.objectValueOrNil?["plugins"]?.objectValueOrNil?["search"]?.objectValueOrNil?["count"]?.doubleValue }.reduce(0, +)
                if count > 0 { parse.usageSearchCalls = Int(count) }
            }
        }
        parse.usage.serverToolCalls = parse.usageSearchCalls
        return parse
    }

    /// 按适配器的完整回执判定。明确 failed/incomplete 不能由 usage 覆盖成成功。
    static func responsesResult(_ root: [String: JSONRuntimeValue], adapterID: String, operation: WebOperation, httpStatus: Int, requestID: String?) -> WebOperationResult {
        let parse = parseResponsesRoot(root, adapterID: adapterID)
        var result = WebOperationResult(operation: operation, adapterID: adapterID, bindingID: nil,
                                        status: .failed, executionEvidence: .none, sourceObservation: .unobservable)
        result.httpStatus = httpStatus
        result.requestID = requestID ?? root["id"]?.stringValue
        result.protocolTerminalState = parse.rootStatus
        result.callIDs = parse.searchCalls.map(\.id) + parse.extractorCalls.map(\.id)
        result.usage = parse.usage
        result.usage.httpRequests = 1
        result.assistantSynthesis = parse.text.isEmpty ? nil : parse.text
        if let structured = WebHTTP.structuredError(root), root["error"] != nil, root["error"] != .null {
            result.errors = [WebAdapterError(kind: .protocolError, message: structured.message, httpStatus: httpStatus, code: structured.code)]
            return result
        }
        if let client = parse.unexpectedClientTool {
            result.errors = [WebAdapterError(kind: .unexpectedClientTool, message: "服务意外要求执行客户端工具 \(client)，已拒绝执行")]
            return result
        }
        switch parse.rootStatus {
        case "completed": break
        case "incomplete":
            result.status = .partial
            result.errors = [WebAdapterError(kind: .protocolError, message: "响应未完整结束（\(parse.incompleteReason ?? "incomplete")）")]
        case "failed":
            result.errors = [WebAdapterError(kind: .serverError, message: "服务端标记响应失败")]
            return result
        case "in_progress", "queued", "searching":
            result.status = .pending
            return result
        default:
            result.errors = [WebAdapterError(kind: .protocolError, message: "响应缺少根终态")]
            return result
        }

        if operation == .fetch {
            let extracted = parse.extractorCalls.filter { ($0.status == nil || $0.status == "completed") && !($0.output ?? "").isEmpty }
            guard !extracted.isEmpty else {
                // 只有搜索没有 extractor 调用时，fetch 未完成。
                result.status = .failed
                result.errors = [WebAdapterError(kind: .unsupportedCapability, message: "服务没有执行网页提取")]
                return result
            }
            result.pages = extracted.map { call in
                WebFetchedContent(
                    requestedURL: URL(string: call.urls.first ?? "") ?? URL(string: "about:blank")!,
                    returnedURL: nil, title: nil, text: call.output, format: "evidence", documentData: nil,
                    mediaType: "text/plain", retrievalStatus: call.status, limitedByService: true, retrievedAt: nil
                )
            }
            result.executionEvidence = .completedServerTool
            result.sourceObservation = .present
            result.resultCapabilities = [.extractedEvidence]
            if result.status != .partial { result.status = .completed }
            return result
        }

        let completedCalls = parse.searchCalls.filter { $0.status == "completed" }
        let failedCalls = parse.searchCalls.filter { $0.status == "failed" || $0.status == "incomplete" }
        let statuslessWithAction = parse.searchCalls.filter { $0.status == nil && $0.hasAction }
        var executed = !completedCalls.isEmpty
        if !executed, !statuslessWithAction.isEmpty, failedCalls.isEmpty {
            switch adapterID {
            case WebAdapterID.xaiResponsesSearch:
                executed = (parse.usageSearchCalls ?? 0) > 0 && !parse.hits.isEmpty
            case WebAdapterID.arkResponsesSearch:
                executed = (parse.usageSearchCalls ?? 0) > 0 && !parse.citedURLs.isEmpty
            default:
                executed = false
            }
        }
        if adapterID == WebAdapterID.arkResponsesSearch, completedCalls.isEmpty, !parse.searchCalls.isEmpty,
           failedCalls.isEmpty, (parse.usageSearchCalls ?? 0) > 0, !parse.citedURLs.isEmpty {
            executed = true
        }
        guard executed else {
            result.status = parse.searchCalls.isEmpty ? .failed : .partial
            result.executionEvidence = .none
            result.errors.append(WebAdapterError(kind: .unsupportedCapability,
                                                 message: parse.searchCalls.isEmpty ? "模型没有调用联网工具（notInvoked）" : "联网工具调用没有完成回执（unverified）"))
            return result
        }
        result.executionEvidence = .completedServerTool
        result.hits = parse.hits
        result.sourceObservation = parse.hits.isEmpty ? .unobservable : .present
        result.resultCapabilities = parse.hits.isEmpty ? [.searchSynthesisOnly] : [.structuredSearchHits, .searchSynthesisOnly]
        if result.status != .partial { result.status = failedCalls.isEmpty ? .completed : .partial }
        return result
    }

    /// 百炼 web_extractor 的流式：按通用 output_item 事件的 item.type 识别；只有根终态才算完成。
    static func accumulateResponsesSSE(_ data: Data) -> (root: [String: JSONRuntimeValue]?, error: WebAdapterError?) {
        guard let text = String(data: data, encoding: .utf8) else {
            return (nil, WebAdapterError(kind: .parseError, message: "流式回包不是 UTF-8"))
        }
        var terminal: [String: JSONRuntimeValue]?
        for record in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let payload = record.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            guard !payload.isEmpty, payload != "[DONE]",
                  let event = WebHTTP.decodeObject(Data(payload.utf8)) else { continue }
            let type = event["type"]?.stringValue ?? ""
            if type == "error" || type == "response.failed" && event["response"] == nil {
                return (nil, WebAdapterError(kind: .serverError, message: event["message"]?.stringValue ?? "流式返回错误"))
            }
            if ["response.completed", "response.incomplete", "response.failed"].contains(type),
               let response = event["response"]?.objectValueOrNil {
                terminal = response
            }
        }
        guard let terminal else { return (nil, WebAdapterError(kind: .protocolError, message: "流在根终态前结束")) }
        return (terminal, nil)
    }

    // MARK: Anthropic Messages

    static func messagesTool(adapterID: String, request: WebAdapterRequest, verification: Bool) -> [String: JSONRuntimeValue] {
        if adapterID == WebAdapterID.anthropicFetch {
            let version = request.options["tool_version"]?.stringValue ?? "web_fetch_20250910"
            var tool: [String: JSONRuntimeValue] = [
                "type": .string(version), "name": .string("web_fetch"),
                "max_uses": .number(verification ? 1 : Double(Int(request.options["max_uses"]?.doubleValue ?? 2))),
                "max_content_tokens": .number(Double(Int(request.options["max_content_tokens"]?.doubleValue ?? 4000))),
                "citations": .object(["enabled": .bool(true)])
            ]
            if version == "web_fetch_20260318" { tool["response_inclusion"] = .string("full") }
            return tool
        }
        let version = request.options["tool_version"]?.stringValue
            ?? (adapterID == WebAdapterID.genericMessagesSearch ? "web_search_20250305" : "web_search_20250305")
        var tool: [String: JSONRuntimeValue] = [
            "type": .string(version), "name": .string("web_search"),
            "max_uses": .number(verification ? 1 : Double(Int(request.options["max_uses"]?.doubleValue ?? (adapterID == WebAdapterID.genericMessagesSearch ? 5 : 3))))
        ]
        if adapterID == WebAdapterID.anthropicSearch { tool["allowed_callers"] = .array([.string("direct")]) }
        if version == "web_search_20260318" { tool["response_inclusion"] = .string("full") }
        return tool
    }

    struct MessagesParse {
        var stopReason: String?
        var content: [JSONRuntimeValue] = []
        var serverUses: [String: String] = [:]
        var searchResults: [String: Result<[WebSearchHit], WebAdapterError>] = [:]
        var fetchResults: [String: Result<WebFetchedContent, WebAdapterError>] = [:]
        var text = ""
        var unexpectedClientTool: String?
        var usage = WebUsage()
    }

    static func parseMessages(_ root: [String: JSONRuntimeValue]) -> MessagesParse {
        var parse = MessagesParse()
        parse.stopReason = root["stop_reason"]?.stringValue
        parse.content = root["content"]?.arrayValue ?? []
        for block in parse.content {
            guard let object = block.objectValueOrNil else { continue }
            switch object["type"]?.stringValue {
            case "server_tool_use":
                parse.serverUses[object["id"]?.stringValue ?? ""] = object["name"]?.stringValue ?? ""
            case "tool_use":
                parse.unexpectedClientTool = object["name"]?.stringValue ?? "tool_use"
            case "web_search_tool_result":
                let id = object["tool_use_id"]?.stringValue ?? ""
                if case .array(let rows)? = object["content"] {
                    let hits = rows.compactMap { row -> WebSearchHit? in
                        guard let item = row.objectValueOrNil, item["type"]?.stringValue == "web_search_result",
                              let url = WebURLValidation.sourceURL(item["url"]) else { return nil }
                        return WebSearchHit(url: url, title: item["title"]?.stringValue, snippet: nil, providerSummary: nil,
                                            content: nil, contentKind: nil, siteName: nil, citationLabel: nil,
                                            date: item["page_age"]?.stringValue, dateKind: item["page_age"] == nil ? nil : .providerUnspecified,
                                            score: nil, sourceType: "web")
                    }
                    parse.searchResults[id] = .success(hits)
                } else if let error = object["content"]?.objectValueOrNil {
                    parse.searchResults[id] = .failure(messagesToolError(error["error_code"]?.stringValue))
                }
            case "web_fetch_tool_result":
                let id = object["tool_use_id"]?.stringValue ?? ""
                guard let content = object["content"]?.objectValueOrNil else { continue }
                if content["type"]?.stringValue == "web_fetch_result" {
                    // 真实路径：web_fetch_tool_result.content.content.source。
                    let document = content["content"]?.objectValueOrNil
                    let source = document?["source"]?.objectValueOrNil
                    let mediaType = source?["media_type"]?.stringValue
                    let isText = source?["type"]?.stringValue == "text"
                    let page = WebFetchedContent(
                        requestedURL: WebURLValidation.sourceURL(content["url"]) ?? URL(string: "about:blank")!,
                        returnedURL: WebURLValidation.sourceURL(content["url"]),
                        title: document?["title"]?.stringValue,
                        text: isText ? source?["data"]?.stringValue : nil,
                        format: isText ? "text" : "pdf",
                        documentData: isText ? nil : source?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) },
                        mediaType: mediaType, retrievalStatus: "ok", limitedByService: true,
                        retrievedAt: content["retrieved_at"]?.stringValue
                    )
                    parse.fetchResults[id] = .success(page)
                } else {
                    parse.fetchResults[id] = .failure(messagesToolError(content["error_code"]?.stringValue))
                }
            case "text":
                parse.text += object["text"]?.stringValue ?? ""
            default:
                break
            }
        }
        if case .object(let usage)? = root["usage"] {
            parse.usage.raw = usage
            parse.usage.modelInputTokens = AnthropicUsageNormalizer.totalInput(usage)
            parse.usage.modelOutputTokens = usage["output_tokens"]?.doubleValue.map { Int($0) }
            parse.usage.serverToolCalls = usage["server_tool_use"]?.objectValueOrNil.map {
                Int(($0["web_search_requests"]?.doubleValue ?? 0) + ($0["web_fetch_requests"]?.doubleValue ?? 0))
            }
        }
        return parse
    }

    static func messagesToolError(_ code: String?) -> WebAdapterError {
        let kind: WebAdapterErrorKind
        switch code {
        case "too_many_requests": kind = .rateLimited
        case "invalid_tool_input", "query_too_long", "url_too_long": kind = .invalidInput
        case "max_uses_exceeded": kind = .budgetExceeded
        case "request_too_large": kind = .requestTooLarge
        case "url_not_allowed", "url_not_in_prior_context": kind = .targetPolicy
        case "url_not_accessible": kind = .targetUnavailable
        case "unsupported_content_type": kind = .unsupportedCapability
        case "unavailable": kind = .serverError
        default: kind = .protocolError
        }
        return WebAdapterError(kind: kind, message: "服务端工具返回错误", code: code)
    }

    static func messagesResult(_ parses: [MessagesParse], adapterID: String, operation: WebOperation, httpStatus: Int, requestID: String?) -> WebOperationResult {
        var result = WebOperationResult(operation: operation, adapterID: adapterID, bindingID: nil,
                                        status: .failed, executionEvidence: .none, sourceObservation: .unobservable)
        result.httpStatus = httpStatus
        result.requestID = requestID
        result.usage.httpRequests = parses.count
        let last = parses.last
        result.protocolTerminalState = last?.stopReason
        result.assistantSynthesis = parses.map(\.text).joined().nilIfEmpty
        for parse in parses {
            result.usage.modelInputTokens = (result.usage.modelInputTokens ?? 0) + (parse.usage.modelInputTokens ?? 0)
            result.usage.modelOutputTokens = (result.usage.modelOutputTokens ?? 0) + (parse.usage.modelOutputTokens ?? 0)
            if let calls = parse.usage.serverToolCalls { result.usage.serverToolCalls = (result.usage.serverToolCalls ?? 0) + calls }
        }
        if let client = parses.compactMap(\.unexpectedClientTool).first {
            result.errors = [WebAdapterError(kind: .unexpectedClientTool, message: "服务意外要求执行客户端工具 \(client)，已拒绝执行")]
            return result
        }
        let searchResults = parses.flatMap { $0.searchResults.map { $0 } }
        let fetchResults = parses.flatMap { $0.fetchResults.map { $0 } }
        let expectedName = operation == .search ? "web_search" : "web_fetch"
        let uses = parses.flatMap { $0.serverUses.filter { $0.value == expectedName }.map(\.key) }
        result.callIDs = uses
        if operation == .search {
            // 成功是数组，错误是对象；单独 server_tool_use 没有配对成功结果不能验证完成。
            let successes = searchResults.compactMap { entry -> [WebSearchHit]? in
                guard uses.contains(entry.key), case .success(let hits) = entry.value else { return nil }
                return hits
            }
            result.errors += searchResults.compactMap { entry in
                if case .failure(let error) = entry.value { return error }
                return nil
            }
            guard !successes.isEmpty else {
                result.status = uses.isEmpty ? .failed : .partial
                if result.errors.isEmpty { result.errors = [WebAdapterError(kind: .unsupportedCapability, message: uses.isEmpty ? "模型没有调用联网工具（notInvoked）" : "联网工具没有返回成功结果")] }
                return result
            }
            result.hits = successes.flatMap { $0 }
            result.executionEvidence = .completedServerTool
            result.sourceObservation = result.hits.isEmpty ? .confirmedEmpty : .present
            result.resultCapabilities = result.hits.isEmpty ? [.searchSynthesisOnly] : [.structuredSearchHits, .searchSynthesisOnly]
        } else {
            let pages = fetchResults.compactMap { entry -> WebFetchedContent? in
                guard uses.contains(entry.key), case .success(let page) = entry.value else { return nil }
                return page
            }
            result.errors += fetchResults.compactMap { entry in
                if case .failure(let error) = entry.value { return error }
                return nil
            }
            guard !pages.isEmpty else {
                result.status = uses.isEmpty ? .failed : .partial
                if result.errors.isEmpty { result.errors = [WebAdapterError(kind: .unsupportedCapability, message: "模型没有执行网页抓取")] }
                return result
            }
            result.pages = pages
            result.executionEvidence = .completedServerTool
            result.sourceObservation = .present
            result.resultCapabilities = [.extractedPageText]
        }
        switch last?.stopReason {
        case "end_turn", "stop_sequence": result.status = result.errors.isEmpty ? .completed : .partial
        case "max_tokens": result.status = .partial; result.notes.append("模型输出被截断")
        case "pause_turn": result.status = .partial; result.notes.append("续传预算耗尽，服务端工具尚未结束")
        default: result.status = .partial; result.notes.append("缺少明确的结束原因")
        }
        return result
    }

    // MARK: Gemini

    static func geminiEndpoint(base: URL, model: String) throws -> URL {
        var id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("models/") { id.removeFirst("models/".count) }
        guard !id.isEmpty, !id.contains("/"), !id.contains("?"), !id.contains("#"),
              let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) else {
            throw WebAdapterError(kind: .invalidInput, message: "Gemini 模型标识无效")
        }
        let text = base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
        guard let url = URL(string: text + "models/" + encoded + ":generateContent") else {
            throw WebAdapterError(kind: .invalidInput, message: "Gemini 端点无效")
        }
        return url
    }

    static func geminiBody(adapterID: String, request: WebAdapterRequest, maxOutputTokens: Int, continuationToken: String?) -> [String: JSONRuntimeValue] {
        let isURLContext = adapterID == WebAdapterID.geminiURLContext
        let prompt = isURLContext
            ? "请读取 \(request.url?.absoluteString ?? "") 并回答与该页有关的问题。" + (request.question.map { "\n问题：" + $0 } ?? "")
            : "请使用 Google Search 查找：" + (request.query ?? "")
        var body: [String: JSONRuntimeValue] = [
            "contents": .array([.object(["role": .string("user"), "parts": .array([.object(["text": .string(prompt)])])])]),
            "tools": .array([.object([isURLContext ? "url_context" : "google_search": .object([:])])]),
            "generationConfig": .object(["candidateCount": .number(1), "maxOutputTokens": .number(Double(maxOutputTokens))])
        ]
        if let continuationToken { body["continuationToken"] = .string(continuationToken) }
        return body
    }

    static func geminiResult(_ root: [String: JSONRuntimeValue], adapterID: String, request: WebAdapterRequest, httpStatus: Int) -> (WebOperationResult, continuation: String?) {
        let operation: WebOperation = adapterID == WebAdapterID.geminiURLContext ? .fetch : .search
        var result = WebOperationResult(operation: operation, adapterID: adapterID, bindingID: nil,
                                        status: .failed, executionEvidence: .none, sourceObservation: .unobservable)
        result.httpStatus = httpStatus
        result.usage.httpRequests = 1
        if let block = root["promptFeedback"]?.objectValueOrNil?["blockReason"]?.stringValue {
            result.errors = [WebAdapterError(kind: .targetPolicy, message: "内容被阻断（\(block)）")]
            return (result, nil)
        }
        guard let candidate = root["candidates"]?.arrayValue?.first?.objectValueOrNil else {
            result.errors = [WebAdapterError(kind: .protocolError, message: "回包没有候选结果")]
            return (result, nil)
        }
        let finish = candidate["finishReason"]?.stringValue
        result.protocolTerminalState = finish
        let text = candidate["content"]?.objectValueOrNil?["parts"]?.arrayValue?.compactMap { $0.objectValueOrNil?["text"]?.stringValue }.joined() ?? ""
        result.assistantSynthesis = text.nilIfEmpty
        if case .object(let usage)? = root["usageMetadata"] {
            result.usage.raw = usage
            result.usage.modelInputTokens = usage["promptTokenCount"]?.doubleValue.map { Int($0) }
            result.usage.modelOutputTokens = usage["candidatesTokenCount"]?.doubleValue.map { Int($0) }
        }
        if finish == "CONTINUATION", let token = root["continuationToken"]?.stringValue ?? candidate["continuationToken"]?.stringValue {
            return (result, token)
        }
        if operation == .search {
            let grounding = candidate["groundingMetadata"]?.objectValueOrNil
            let chunks = grounding?["groundingChunks"]?.arrayValue ?? []
            let queries = grounding?["webSearchQueries"]?.arrayValue ?? []
            let hits = chunks.compactMap { chunk -> WebSearchHit? in
                // 来源必须使用有效 URL 的 web.uri；单独标题不能充当来源。Google 跳转 URI 原样保存。
                guard let web = chunk.objectValueOrNil?["web"]?.objectValueOrNil,
                      let url = WebURLValidation.sourceURL(web["uri"]) else { return nil }
                return WebSearchHit(url: url, title: web["title"]?.stringValue, snippet: nil, providerSummary: nil,
                                    content: nil, contentKind: nil, siteName: nil, citationLabel: nil, date: nil,
                                    dateKind: nil, score: nil, sourceType: "grounding")
            }
            let supports = grounding?["groundingSupports"]?.arrayValue ?? []
            let linked = supports.contains { support in
                !(support.objectValueOrNil?["groundingChunkIndices"]?.arrayValue ?? []).isEmpty
            }
            guard finish == "STOP" else {
                result.status = finish == "MAX_TOKENS" ? .partial : .failed
                result.errors = [WebAdapterError(kind: finish == "SAFETY" ? .targetPolicy : .protocolError, message: "结束原因：\(finish ?? "无")")]
                return (result, nil)
            }
            guard !queries.isEmpty || !hits.isEmpty else {
                result.status = .failed
                result.errors = [WebAdapterError(kind: .unsupportedCapability, message: "没有 grounding 元数据，未证明执行了搜索（unverified）")]
                return (result, nil)
            }
            result.hits = hits
            result.executionEvidence = .metadataGrounding
            result.sourceObservation = hits.isEmpty ? .unobservable : .present
            result.resultCapabilities = hits.isEmpty ? [.searchSynthesisOnly] : [.structuredSearchHits, .searchSynthesisOnly]
            result.status = .completed
            if !linked && !hits.isEmpty { result.notes.append("回答片段与来源的关联未返回") }
            if let entry = grounding?["searchEntryPoint"]?.objectValueOrNil, entry["renderedContent"] != nil {
                result.notes.append("服务商要求展示搜索入口（searchEntryPoint）；不作为可信脚本注入")
            }
            return (result, nil)
        }
        // URL Context：逐目标判定读取状态；别的 URL 成功不能覆盖当前目标失败。
        let metadata = candidate["urlContextMetadata"]?.objectValueOrNil?["urlMetadata"]?.arrayValue ?? []
        let target = request.url?.absoluteString
        let entry = metadata.compactMap(\.objectValueOrNil).first { $0["retrievedUrl"]?.stringValue == target } ?? metadata.first?.objectValueOrNil
        let status = entry?["urlRetrievalStatus"]?.stringValue
        guard finish == "STOP", status == "URL_RETRIEVAL_STATUS_SUCCESS" else {
            result.status = finish == "MAX_TOKENS" ? .partial : .failed
            let kind: WebAdapterErrorKind = status == "URL_RETRIEVAL_STATUS_PAYWALL" || status == "URL_RETRIEVAL_STATUS_UNSAFE" ? .targetPolicy
                : status == "URL_RETRIEVAL_STATUS_ERROR" ? .targetUnavailable : .protocolError
            result.errors = [WebAdapterError(kind: kind, message: "网页读取状态：\(status ?? "未知")，结束原因：\(finish ?? "无")")]
            return (result, nil)
        }
        result.pages = [WebFetchedContent(
            requestedURL: request.url ?? URL(string: "about:blank")!, returnedURL: nil, title: nil, text: text,
            format: "model_analysis", documentData: nil, mediaType: "text/plain", retrievalStatus: status,
            limitedByService: true, retrievedAt: nil
        )]
        result.executionEvidence = .metadataGrounding
        result.sourceObservation = .present
        result.resultCapabilities = [.modelURLAnalysis]
        result.status = .completed
        return (result, nil)
    }

    // MARK: Qwen Chat enable_search

    static func qwenChatBody(model: String, request: WebAdapterRequest) -> [String: JSONRuntimeValue] {
        // enable_search 与 search_options 是 HTTP 顶层字段，不是名为 extra_body 的外层 JSON。
        [
            "model": .string(model),
            "messages": .array([.object(["role": .string("user"), "content": .string(searchPrompt + (request.query ?? ""))])]),
            "enable_search": .bool(true),
            "search_options": .object(["forced_search": .bool(true), "search_strategy": .string(request.options["search_strategy"]?.stringValue ?? "turbo")]),
            "stream": .bool(false)
        ]
    }

    static func qwenChatResult(_ root: [String: JSONRuntimeValue], httpStatus: Int) -> WebOperationResult {
        var result = WebOperationResult(operation: .search, adapterID: WebAdapterID.qwenChatSearch, bindingID: nil,
                                        status: .failed, executionEvidence: .none, sourceObservation: .unobservable)
        result.httpStatus = httpStatus
        result.usage.httpRequests = 1
        if let structured = WebHTTP.structuredError(root), root["error"] != nil {
            result.errors = [WebAdapterError(kind: .protocolError, message: structured.message, code: structured.code)]
            return result
        }
        guard let choice = root["choices"]?.arrayValue?.first?.objectValueOrNil,
              let content = choice["message"]?.objectValueOrNil?["content"]?.stringValue else {
            result.errors = [WebAdapterError(kind: .parseError, message: "回包缺少 choices.message.content")]
            return result
        }
        let finish = choice["finish_reason"]?.stringValue
        result.protocolTerminalState = finish
        result.assistantSynthesis = content
        // 该合同不保证结构化来源；不把正文中的 URL 当作已验证的搜索证据。
        result.executionEvidence = .declaredOnly
        result.resultCapabilities = [.searchSynthesisOnly]
        result.status = finish == "length" ? .partial : (finish == "stop" ? .completed : .partial)
        return result
    }

    // MARK: 执行

    static func execute(adapterID: String, request: WebAdapterRequest, context: inout WebAdapterContext) async -> WebOperationResult {
        let operation: WebOperation = [WebAdapterID.anthropicFetch, WebAdapterID.qwenResponsesExtractor, WebAdapterID.geminiURLContext].contains(adapterID) ? .fetch : .search
        guard let model = context.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return WebIndependentAdapters.failure(operation, adapter: adapterID, error: WebAdapterError(kind: .invalidInput, message: "服务端网页工具需要选择一个模型"))
        }
        do {
            switch adapterID {
            case WebAdapterID.openAIResponsesSearch, WebAdapterID.deepSeekResponsesSearch, WebAdapterID.xaiResponsesSearch,
                 WebAdapterID.arkResponsesSearch, WebAdapterID.qwenResponsesSearch, WebAdapterID.qwenResponsesExtractor,
                 WebAdapterID.genericResponsesSearch:
                var extra = context.extraHeaders
                if adapterID == WebAdapterID.arkResponsesSearch, extra.keys.first(where: { $0.lowercased() == "ark-beta-web-search" }) == nil {
                    extra["ark-beta-web-search"] = "true"
                }
                var headers = WebHTTP.headers(style: .bearer, apiKey: context.apiKey, extra: extra)
                if adapterID == WebAdapterID.qwenResponsesExtractor { headers["Accept"] = "text/event-stream" }
                let body = try responsesBody(adapterID: adapterID, model: model, request: request, verification: context.isVerification)
                let (data, response) = try await WebHTTP.post(context.endpoint, body: body, headers: headers, context: &context)
                if let error = WebIndependentAdapters.httpError(data, response, targetContext: false) {
                    return WebIndependentAdapters.failure(operation, adapter: adapterID, error: error, status: response.statusCode)
                }
                let root: [String: JSONRuntimeValue]
                if adapterID == WebAdapterID.qwenResponsesExtractor {
                    let accumulated = accumulateResponsesSSE(data)
                    if let error = accumulated.error { return WebIndependentAdapters.failure(operation, adapter: adapterID, error: error, status: response.statusCode) }
                    root = accumulated.root ?? [:]
                } else {
                    guard let decoded = WebHTTP.decodeObject(data) else {
                        return WebIndependentAdapters.failure(operation, adapter: adapterID, error: WebAdapterError(kind: .parseError, message: "回包不是 JSON 对象"), status: response.statusCode)
                    }
                    root = decoded
                }
                return responsesResult(root, adapterID: adapterID, operation: operation, httpStatus: response.statusCode, requestID: WebHTTP.requestID(response))

            case WebAdapterID.anthropicSearch, WebAdapterID.anthropicFetch, WebAdapterID.genericMessagesSearch:
                var headers = WebHTTP.headers(style: .anthropic, apiKey: context.apiKey, extra: context.extraHeaders)
                if adapterID == WebAdapterID.genericMessagesSearch, request.options["also_send_bearer"]?.boolValue == true, let key = context.apiKey {
                    headers["Authorization"] = "Bearer \(key)"
                }
                let userText = operation == .fetch
                    ? fetchPrompt + (request.url?.absoluteString ?? "") + (request.question.map { "\n问题：" + $0 } ?? "")
                    : searchPrompt + (request.query ?? "")
                var messages: [JSONRuntimeValue] = [.object(["role": .string("user"), "content": .string(userText)])]
                var parses: [MessagesParse] = []
                var lastStatus = 0
                var requestID: String?
                while true {
                    let body: [String: JSONRuntimeValue] = [
                        "model": .string(model), "max_tokens": .number(2048), "messages": .array(messages),
                        "tools": .array([.object(messagesTool(adapterID: adapterID, request: request, verification: context.isVerification))]),
                        "stream": .bool(false)
                    ]
                    let (data, response) = try await WebHTTP.post(context.endpoint, body: body, headers: headers, context: &context)
                    lastStatus = response.statusCode
                    requestID = WebHTTP.requestID(response) ?? requestID
                    if let error = WebIndependentAdapters.httpError(data, response, targetContext: false) {
                        return WebIndependentAdapters.failure(operation, adapter: adapterID, error: error, status: response.statusCode)
                    }
                    guard let root = WebHTTP.decodeObject(data) else {
                        return WebIndependentAdapters.failure(operation, adapter: adapterID, error: WebAdapterError(kind: .parseError, message: "回包不是 JSON 对象"))
                    }
                    let parse = parseMessages(root)
                    parses.append(parse)
                    // pause_turn：原样追加 assistant content 继续请求，不伪造 user continue，不把服务端工具转成本地执行。
                    guard parse.stopReason == "pause_turn", parse.unexpectedClientTool == nil else { break }
                    do { try context.budget.admitContinuation() } catch { break }
                    messages.append(.object(["role": .string("assistant"), "content": .array(parse.content)]))
                }
                return messagesResult(parses, adapterID: adapterID, operation: operation, httpStatus: lastStatus, requestID: requestID)

            case WebAdapterID.geminiSearch, WebAdapterID.geminiURLContext:
                let endpoint = try geminiEndpoint(base: context.endpoint, model: model)
                let headers = WebHTTP.headers(style: .googleAPIKey, apiKey: context.apiKey, extra: context.extraHeaders)
                var maxOutput = 2048
                var token: String?
                var combinedText = ""
                while true {
                    let body = geminiBody(adapterID: adapterID, request: request, maxOutputTokens: maxOutput, continuationToken: token)
                    let (data, response) = try await WebHTTP.post(endpoint, body: body, headers: headers, context: &context)
                    if let error = WebIndependentAdapters.httpError(data, response, targetContext: adapterID == WebAdapterID.geminiURLContext) {
                        return WebIndependentAdapters.failure(operation, adapter: adapterID, error: error, status: response.statusCode)
                    }
                    guard let root = WebHTTP.decodeObject(data) else {
                        return WebIndependentAdapters.failure(operation, adapter: adapterID, error: WebAdapterError(kind: .parseError, message: "回包不是 JSON 对象"))
                    }
                    var (result, continuation) = geminiResult(root, adapterID: adapterID, request: request, httpStatus: response.statusCode)
                    combinedText += result.assistantSynthesis ?? ""
                    guard let continuation else {
                        result.assistantSynthesis = combinedText.nilIfEmpty
                        result.usage.httpRequests = context.requestCounter.value
                        return result
                    }
                    // 续传：contents 与最初完全相同，顶层原样传回 token；maxOutputTokens 是累计上限，只在预算内单调增加。
                    do { try context.budget.admitContinuation() } catch {
                        result.status = .budgetExceeded
                        return result
                    }
                    token = continuation
                    maxOutput = min(8_192, maxOutput * 2)
                }

            case WebAdapterID.qwenChatSearch:
                let headers = WebHTTP.headers(style: .bearer, apiKey: context.apiKey, extra: context.extraHeaders)
                let (data, response) = try await WebHTTP.post(context.endpoint, body: qwenChatBody(model: model, request: request), headers: headers, context: &context)
                if let error = WebIndependentAdapters.httpError(data, response, targetContext: false) {
                    return WebIndependentAdapters.failure(operation, adapter: adapterID, error: error, status: response.statusCode)
                }
                guard let root = WebHTTP.decodeObject(data) else {
                    return WebIndependentAdapters.failure(operation, adapter: adapterID, error: WebAdapterError(kind: .parseError, message: "回包不是 JSON 对象"))
                }
                return qwenChatResult(root, httpStatus: response.statusCode)

            default:
                return WebIndependentAdapters.failure(operation, adapter: adapterID, error: WebAdapterError(kind: .unsupportedCapability, message: "未知的服务端网页适配器"))
            }
        } catch let error as WebAdapterError {
            return WebIndependentAdapters.failure(operation, adapter: adapterID, error: error)
        } catch {
            return WebIndependentAdapters.failure(operation, adapter: adapterID, error: WebAdapterError(kind: .network, message: error.localizedDescription))
        }
    }
}

/// Anthropic 的 input_tokens 不含缓存；规范化总输入 = input + cache_read + cache_creation。缺失字段保持未知。
nonisolated enum AnthropicUsageNormalizer {
    static func totalInput(_ usage: [String: JSONRuntimeValue]) -> Int? {
        guard let input = usage["input_tokens"]?.doubleValue else { return nil }
        let read = usage["cache_read_input_tokens"]?.doubleValue ?? 0
        let creation = usage["cache_creation_input_tokens"]?.doubleValue ?? 0
        return Int(input + read + creation)
    }
}
