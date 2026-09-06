import Foundation
import Testing
@testable import PalmiAgent

@Suite(.serialized)
struct RemoteWebSearchServiceTests {
    @Test(arguments: [
        ("https://api.anthropic.com", "https://api.anthropic.com/v1/messages"),
        ("https://api.anthropic.com/v1", "https://api.anthropic.com/v1/messages"),
        ("https://api.deepseek.com/anthropic/v1", "https://api.deepseek.com/anthropic/v1/messages"),
        ("https://example.com/custom/messages", "https://example.com/custom/messages")
    ])
    func messagesURLResolution(input: String, expected: String) throws {
        #expect(try RemoteSearchEndpointResolver.messagesURL(from: input).absoluteString == expected)
    }

    @Test
    func responsesRequestUsesServerWebSearchTool() async throws {
        RemoteWebSearchURLProtocol.handler = { request in
            let request = request.materializingHTTPBodyForTesting()
            #expect(request.url?.absoluteString == "https://example.com/v1/responses")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer response-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let bodyData = try #require(request.httpBody)
            let body = try #require(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            #expect(body["model"] as? String == "response-model")
            #expect(body["stream"] as? Bool == false)
            let tools = try #require(body["tools"] as? [[String: Any]])
            #expect(tools.count == 1)
            #expect(tools[0]["type"] as? String == "web_search")
            #expect((body["input"] as? String)?.contains("original query") == true)
            return (200, #"{"output":[{"type":"web_search_call"},{"type":"message","content":[{"type":"output_text","text":"Answer"}]}]}"#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        let result = try await service.search(
            query: "original query",
            configuration: snapshot(protocol: .responses, modelName: "response-model"),
            apiKey: "response-key",
            maxResults: 5
        )

        #expect(result.answer == "Answer")
    }

    @Test
    func responsesParsingDeduplicatesSourcesAndHonorsLimit() async throws {
        RemoteWebSearchURLProtocol.handler = { _ in
            (200, #"""
            {
              "output": [
                {
                  "type": "web_search_call",
                  "action": {"type": "search", "sources": [
                    {"url": "https://example.com/a", "title": "Source A", "snippet": "Snippet A"}
                  ]}
                },
                {
                  "type": "message",
                  "content": [{
                    "type": "output_text",
                    "text": "Final answer",
                    "annotations": [
                      {"type": "url_citation", "url": "https://example.com/a", "title": "Source A"},
                      {"type": "url_citation", "url_citation": {"url": "https://example.com/b", "title": "Source B"}}
                    ]
                  }]
                }
              ]
            }
            """#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        let result = try await service.search(
            query: "test",
            configuration: snapshot(protocol: .responses),
            apiKey: "key",
            maxResults: 2
        )
        let limited = try await service.search(
            query: "test",
            configuration: snapshot(protocol: .responses),
            apiKey: "key",
            maxResults: 1
        )

        #expect(result.answer == "Final answer")
        #expect(result.sources.map(\.url.absoluteString) == [
            "https://example.com/a",
            "https://example.com/b"
        ])
        #expect(limited.sources.map(\.url.absoluteString) == ["https://example.com/a"])
    }

    @Test
    func messagesRequestUsesExpectedHeadersAndToolContract() async throws {
        RemoteWebSearchURLProtocol.handler = { request in
            let request = request.materializingHTTPBodyForTesting()
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "messages-key")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer messages-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            let bodyData = try #require(request.httpBody)
            let body = try #require(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            #expect(body["max_tokens"] as? Int == 4096)
            #expect(body["stream"] as? Bool == false)
            let tools = try #require(body["tools"] as? [[String: Any]])
            #expect(tools[0]["type"] as? String == "web_search_20250305")
            #expect(tools[0]["name"] as? String == "web_search")
            #expect(tools[0]["max_uses"] as? Int == 5)
            let messages = try #require(body["messages"] as? [[String: Any]])
            let content = try #require(messages[0]["content"] as? [[String: Any]])
            #expect((content[0]["text"] as? String)?.contains("messages query") == true)
            return (200, #"{"content":[{"type":"server_tool_use","name":"web_search"},{"type":"text","text":"Answer"}]}"#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        let result = try await service.search(
            query: "messages query",
            configuration: snapshot(
                protocol: .messages,
                baseURLString: "https://api.anthropic.com",
                modelName: "messages-model"
            ),
            apiKey: "messages-key",
            maxResults: 5
        )

        #expect(result.answer == "Answer")
    }

    @Test
    func responsesConnectivityValidationDoesNotRequestWebSearch() async throws {
        RemoteWebSearchURLProtocol.handler = { request in
            let request = request.materializingHTTPBodyForTesting()
            let bodyData = try #require(request.httpBody)
            let body = try #require(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            #expect(request.url?.absoluteString == "https://example.com/v1/responses")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer validation-key")
            #expect(body["model"] as? String == "validation-model")
            #expect(body["tools"] == nil)
            #expect(body["stream"] as? Bool == false)
            return (200, #"{"output_text":"OK"}"#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        try await service.validateConnectivity(
            configuration: snapshot(
                protocol: .responses,
                modelName: "validation-model"
            ),
            apiKey: "validation-key"
        )
    }

    @Test
    func messagesConnectivityValidationUsesMessagesEndpointWithoutSearchTool() async throws {
        RemoteWebSearchURLProtocol.handler = { request in
            let request = request.materializingHTTPBodyForTesting()
            let bodyData = try #require(request.httpBody)
            let body = try #require(
                JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            )
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "validation-key")
            #expect(body["max_tokens"] as? Int == 1)
            #expect(body["tools"] == nil)
            #expect(body["stream"] as? Bool == false)
            return (200, #"{"content":[{"type":"text","text":"OK"}]}"#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        try await service.validateConnectivity(
            configuration: snapshot(
                protocol: .messages,
                baseURLString: "https://api.anthropic.com",
                modelName: "validation-model"
            ),
            apiKey: "validation-key"
        )
    }

    @Test
    func messagesParsingMergesCitationIntoSearchResult() async throws {
        RemoteWebSearchURLProtocol.handler = { _ in
            (200, #"""
            {
              "content": [
                {"type":"server_tool_use","name":"web_search","input":{"query":"test"}},
                {"type":"web_search_tool_result","content":[
                  {"type":"web_search_result","url":"https://example.com/a","title":"Source A","page_age":"2026-08-30"}
                ]},
                {"type":"text","text":"Final answer","citations":[
                  {"type":"web_search_result_location","url":"https://example.com/a","title":"Source A","cited_text":"Citation excerpt"}
                ]}
              ]
            }
            """#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        let result = try await service.search(
            query: "test",
            configuration: snapshot(protocol: .messages),
            apiKey: "key",
            maxResults: 5
        )

        #expect(result.answer == "Final answer")
        #expect(result.sources.count == 1)
        #expect(result.sources[0].snippet == "Citation excerpt")
        #expect(result.sources[0].publishedAt == "2026-08-30")
    }

    @Test
    func plainTextWithoutSearchEvidenceFails() async throws {
        RemoteWebSearchURLProtocol.handler = { _ in
            (200, #"{"output_text":"An unsupported plain answer"}"#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        let message = await errorMessage {
            try await service.search(
                query: "test",
                configuration: snapshot(protocol: .responses),
                apiKey: "key",
                maxResults: 5
            )
        }

        #expect(message == "远端模型没有执行网页搜索。")
    }

    @Test
    func httpErrorExtractsErrorMessage() async throws {
        RemoteWebSearchURLProtocol.handler = { _ in
            (401, #"{"error":{"message":"Invalid remote key"}}"#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        let message = await errorMessage {
            try await service.search(
                query: "test",
                configuration: snapshot(protocol: .responses),
                apiKey: "key",
                maxResults: 5
            )
        }

        #expect(message?.contains("Invalid remote key") == true)
    }

    @Test
    func emptySearchResultFailsClearly() async throws {
        RemoteWebSearchURLProtocol.handler = { _ in
            (200, #"{"output":[{"type":"web_search_call"}]}"#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        let message = await errorMessage {
            try await service.search(
                query: "test",
                configuration: snapshot(protocol: .responses),
                apiKey: "key",
                maxResults: 5
            )
        }

        #expect(message == "远端搜索没有返回可用结果。")
    }

    @Test
    func fragmentsAreRemovedBeforeDeduplication() async throws {
        RemoteWebSearchURLProtocol.handler = { _ in
            (200, #"""
            {"output":[{"type":"web_search_call","sources":[
              {"url":"https://example.com/a#first","title":"First"},
              {"url":"https://example.com/a#second","snippet":"Second snippet"}
            ]}]}
            """#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        let result = try await service.search(
            query: "test",
            configuration: snapshot(protocol: .responses),
            apiKey: "key",
            maxResults: 5
        )

        #expect(result.sources.count == 1)
        #expect(result.sources[0].url.absoluteString == "https://example.com/a")
        #expect(result.sources[0].snippet == "Second snippet")
    }

    @Test
    func laterCitationOnlyFillsMissingFields() async throws {
        RemoteWebSearchURLProtocol.handler = { _ in
            (200, #"""
            {"content":[
              {"type":"web_search_tool_result","content":[
                {"type":"web_search_result","url":"https://example.com/a","title":"Original title","snippet":"Original snippet"}
              ]},
              {"type":"text","text":"Answer","citations":[
                {"url":"https://example.com/a","title":"Replacement title","cited_text":"Replacement snippet","published_at":"2026-08-31"}
              ]}
            ]}
            """#)
        }
        let service = RemoteWebSearchService(session: makeSession())

        let result = try await service.search(
            query: "test",
            configuration: snapshot(protocol: .messages),
            apiKey: "key",
            maxResults: 5
        )

        #expect(result.sources[0].title == "Original title")
        #expect(result.sources[0].snippet == "Original snippet")
        #expect(result.sources[0].publishedAt == "2026-08-31")
    }

    private func snapshot(
        protocol apiProtocol: RemoteSearchAPIProtocol,
        baseURLString: String = "https://example.com/v1",
        modelName: String = "model"
    ) -> RemoteSearchConfigurationSnapshot {
        RemoteSearchConfigurationSnapshot(
            record: RemoteSearchConfigurationRecord(
                id: UUID(),
                displayName: "Test Search",
                baseURLString: baseURLString,
                modelName: modelName,
                apiProtocol: apiProtocol,
                createdAt: .now,
                updatedAt: .now
            ),
            hasAPIKey: true,
            maskedAPIKey: "••••"
        )
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteWebSearchURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func errorMessage(
        _ operation: () async throws -> RemoteWebSearchResult
    ) async -> String? {
        do {
            _ = try await operation()
            Issue.record("Expected operation to throw")
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private final class RemoteWebSearchURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (statusCode: Int, body: String)

    nonisolated(unsafe) static var handler: Handler?

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let result = try handler(request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(result.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    nonisolated override func stopLoading() {}
}
