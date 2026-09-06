import Foundation

struct RemoteWebSearchSource: Equatable, Sendable {
    let url: URL
    var title: String?
    var snippet: String?
    var publishedAt: String?
}

struct RemoteWebSearchResult: Equatable, Sendable {
    let answer: String?
    let sources: [RemoteWebSearchSource]
}

enum RemoteSearchEndpointResolver {
    static func responsesURL(from rawValue: String) throws -> URL {
        try OpenAICompatibleEndpointResolver.resolve(rawValue).responsesURL
    }

    static func messagesURL(from rawValue: String) throws -> URL {
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AppError.invalidState("Base URL 不能为空。")
        }
        if !normalized.contains("://") {
            normalized = "https://\(normalized)"
        }

        guard var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw AppError.invalidState("请输入有效的 HTTP 或 HTTPS Base URL。")
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        let lastComponent = components.path.split(separator: "/").last.map(String.init)
        switch lastComponent {
        case "messages":
            break
        case "v1":
            components.path += "/messages"
        default:
            let prefix = components.path.isEmpty || components.path == "/"
                ? ""
                : components.path
            components.path = "\(prefix)/v1/messages"
        }

        guard let url = components.url else {
            throw AppError.invalidState("请输入有效的 HTTP 或 HTTPS Base URL。")
        }
        return url
    }
}

final class RemoteWebSearchService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validateConnectivity(
        configuration: RemoteSearchConfigurationSnapshot,
        apiKey: String,
        timeoutSeconds: TimeInterval = 15
    ) async throws {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty else {
            throw AppError.invalidState("API Key 不能为空。")
        }
        guard !trimmedModelName.isEmpty else {
            throw AppError.invalidState("模型名称不能为空。")
        }

        let request: URLRequest
        switch configuration.apiProtocol {
        case .responses:
            let endpoint = try RemoteSearchEndpointResolver.responsesURL(
                from: configuration.baseURLString
            )
            var responsesRequest = URLRequest(url: endpoint, timeoutInterval: timeoutSeconds)
            responsesRequest.httpMethod = "POST"
            responsesRequest.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
            responsesRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            responsesRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            responsesRequest.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": trimmedModelName,
                "input": "Reply with OK.",
                "stream": false
            ])
            request = responsesRequest
        case .messages:
            let endpoint = try RemoteSearchEndpointResolver.messagesURL(
                from: configuration.baseURLString
            )
            var messagesRequest = URLRequest(url: endpoint, timeoutInterval: timeoutSeconds)
            messagesRequest.httpMethod = "POST"
            messagesRequest.setValue(trimmedAPIKey, forHTTPHeaderField: "x-api-key")
            messagesRequest.setValue("Bearer \(trimmedAPIKey)", forHTTPHeaderField: "Authorization")
            messagesRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            messagesRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            messagesRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            messagesRequest.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": trimmedModelName,
                "max_tokens": 1,
                "messages": [[
                    "role": "user",
                    "content": [["type": "text", "text": "Reply with OK."]]
                ]],
                "stream": false
            ])
            request = messagesRequest
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppError.operationFailed("连接验证失败：\(error.localizedDescription)")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.operationFailed("连接验证返回了无效响应。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data)
                ?? "连接验证失败（HTTP \(httpResponse.statusCode)）。"
            throw AppError.operationFailed(message)
        }
    }

    func search(
        query: String,
        configuration: RemoteSearchConfigurationSnapshot,
        apiKey: String,
        maxResults: Int,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> RemoteWebSearchResult {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = configuration.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw AppError.invalidState("搜索关键词不能为空。")
        }
        guard !trimmedAPIKey.isEmpty else {
            throw AppError.invalidState("API Key 不能为空。")
        }
        guard !trimmedModelName.isEmpty else {
            throw AppError.invalidState("模型名称不能为空。")
        }

        let request: URLRequest
        switch configuration.apiProtocol {
        case .responses:
            request = try responsesRequest(
                query: trimmedQuery,
                configuration: configuration,
                modelName: trimmedModelName,
                apiKey: trimmedAPIKey,
                timeoutSeconds: timeoutSeconds
            )
        case .messages:
            request = try messagesRequest(
                query: trimmedQuery,
                configuration: configuration,
                modelName: trimmedModelName,
                apiKey: trimmedAPIKey,
                timeoutSeconds: timeoutSeconds
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppError.operationFailed("远端搜索请求失败：\(error.localizedDescription)")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.operationFailed("远端搜索返回了无效响应。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data)
                ?? "远端搜索请求失败（HTTP \(httpResponse.statusCode)）。"
            throw AppError.operationFailed(message)
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AppError.operationFailed("远端搜索返回了无效 JSON。")
        }
        guard let root = object as? [String: Any] else {
            throw AppError.operationFailed("远端搜索返回了无效结果。")
        }

        let parsed: ParsedSearchResponse
        switch configuration.apiProtocol {
        case .responses:
            parsed = Self.parseResponses(root)
        case .messages:
            parsed = Self.parseMessages(root)
        }

        let normalizedSources = Array(parsed.sources.prefix(max(1, maxResults)))
        let answer = Self.joinedAnswer(parsed.answerFragments)
        guard parsed.didUseSearch || !normalizedSources.isEmpty else {
            throw AppError.operationFailed("远端模型没有执行网页搜索。")
        }
        guard answer != nil || !normalizedSources.isEmpty else {
            throw AppError.operationFailed("远端搜索没有返回可用结果。")
        }
        return RemoteWebSearchResult(answer: answer, sources: normalizedSources)
    }

    private func responsesRequest(
        query: String,
        configuration: RemoteSearchConfigurationSnapshot,
        modelName: String,
        apiKey: String,
        timeoutSeconds: TimeInterval
    ) throws -> URLRequest {
        let endpoint = try RemoteSearchEndpointResolver.responsesURL(
            from: configuration.baseURLString
        )
        var request = URLRequest(url: endpoint, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "input": "Use the available web_search server tool to search the web for the following query. You must actually call web_search. Return a concise factual answer and preserve the sources used.\n\nQuery: \(query)",
            "tools": [["type": "web_search"]],
            "stream": false
        ])
        return request
    }

    private func messagesRequest(
        query: String,
        configuration: RemoteSearchConfigurationSnapshot,
        modelName: String,
        apiKey: String,
        timeoutSeconds: TimeInterval
    ) throws -> URLRequest {
        let endpoint = try RemoteSearchEndpointResolver.messagesURL(
            from: configuration.baseURLString
        )
        var request = URLRequest(url: endpoint, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "max_tokens": 4096,
            "messages": [[
                "role": "user",
                "content": [[
                    "type": "text",
                    "text": "Use the available web_search server tool to search the web for the following query. You must actually call web_search. Return a concise factual answer and preserve the sources used.\n\nQuery:\n\(query)"
                ]]
            ]],
            "tools": [[
                "type": "web_search_20250305",
                "name": "web_search",
                "max_uses": 5
            ]],
            "stream": false
        ])
        return request
    }

    private static func parseResponses(_ root: [String: Any]) -> ParsedSearchResponse {
        var fragments: [String] = []
        var accumulator = SourceAccumulator()
        var didUseSearch = false

        if let outputText = root["output_text"] as? String {
            fragments.append(outputText)
        }
        for item in root["output"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "web_search_call":
                didUseSearch = true
                accumulator.add(contentsOf: item["sources"] as? [[String: Any]] ?? [])
                if let action = item["action"] as? [String: Any] {
                    accumulator.add(contentsOf: action["sources"] as? [[String: Any]] ?? [])
                }
            case "message":
                for block in item["content"] as? [[String: Any]] ?? [] {
                    let type = block["type"] as? String
                    if type == "output_text" || type == "text",
                       let text = block["text"] as? String {
                        fragments.append(text)
                    }
                    for annotation in block["annotations"] as? [[String: Any]] ?? [] {
                        let citation = annotation["url_citation"] as? [String: Any] ?? annotation
                        accumulator.add(dictionary: citation)
                    }
                }
            default:
                break
            }
        }
        return ParsedSearchResponse(
            answerFragments: fragments,
            sources: accumulator.sources,
            didUseSearch: didUseSearch || !accumulator.sources.isEmpty
        )
    }

    private static func parseMessages(_ root: [String: Any]) -> ParsedSearchResponse {
        var fragments: [String] = []
        var accumulator = SourceAccumulator()
        var didUseSearch = false

        for block in root["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "server_tool_use":
                if block["name"] as? String == "web_search" {
                    didUseSearch = true
                }
            case "web_search_tool_result":
                didUseSearch = true
                for result in block["content"] as? [[String: Any]] ?? []
                    where result["type"] as? String == "web_search_result" {
                    accumulator.add(dictionary: result)
                }
            case "text":
                if let text = block["text"] as? String {
                    fragments.append(text)
                }
                for citation in block["citations"] as? [[String: Any]] ?? [] {
                    accumulator.add(dictionary: citation)
                }
            default:
                break
            }
        }
        return ParsedSearchResponse(
            answerFragments: fragments,
            sources: accumulator.sources,
            didUseSearch: didUseSearch || !accumulator.sources.isEmpty
        )
    }

    private static func joinedAnswer(_ fragments: [String]) -> String? {
        var seen = Set<String>()
        let unique = fragments.compactMap { fragment -> String? in
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
        return unique.isEmpty ? nil : unique.joined(separator: "\n\n")
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = root["error"] as? [String: Any],
           let message = nonEmptyString(error["message"]) {
            return message
        }
        for key in ["error", "message", "detail"] {
            if let message = nonEmptyString(root[key]) {
                return message
            }
        }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ParsedSearchResponse {
    let answerFragments: [String]
    let sources: [RemoteWebSearchSource]
    let didUseSearch: Bool
}

private struct SourceAccumulator {
    private(set) var sources: [RemoteWebSearchSource] = []
    private var indexByURL: [String: Int] = [:]

    mutating func add(contentsOf dictionaries: [[String: Any]]) {
        dictionaries.forEach { add(dictionary: $0) }
    }

    mutating func add(dictionary: [String: Any]) {
        guard let rawURL = firstString(in: dictionary, keys: ["url"]),
              let url = normalizedURL(rawURL) else {
            return
        }
        let key = url.absoluteString
        let title = firstString(in: dictionary, keys: ["title", "name"])
        let snippet = firstString(
            in: dictionary,
            keys: ["snippet", "content", "cited_text"]
        )
        let publishedAt = firstString(
            in: dictionary,
            keys: ["published_at", "publishedAt", "page_age"]
        )

        if let index = indexByURL[key] {
            if sources[index].title == nil { sources[index].title = title }
            if sources[index].snippet == nil { sources[index].snippet = snippet }
            if sources[index].publishedAt == nil { sources[index].publishedAt = publishedAt }
            return
        }

        indexByURL[key] = sources.count
        sources.append(
            RemoteWebSearchSource(
                url: url,
                title: title,
                snippet: snippet,
                publishedAt: publishedAt
            )
        )
    }

    private func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dictionary[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func normalizedURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        components.scheme = scheme
        components.fragment = nil
        return components.url
    }
}
