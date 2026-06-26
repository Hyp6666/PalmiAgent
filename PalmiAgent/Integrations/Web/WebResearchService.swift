import CoreFoundation
import Foundation
import PDFKit
import SafariServices
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct WebSearchResult: Sendable {
    let title: String
    let url: URL
    let snippet: String
}

enum WebExtractionMode: String, Sendable {
    case staticHTML = "static_html"
    case renderedHTML = "rendered_html"
    case pdf = "pdf"
    case plainText = "plain_text"
    case json = "json"
    case xml = "xml"
}

struct WebDocumentLink: Sendable {
    let title: String
    let url: URL
}

struct WebFetchSummary: Sendable {
    let requestedURL: URL
    let finalURL: URL
    let title: String
    let canonicalURL: URL?
    let siteName: String?
    let author: String?
    let publishedAt: String?
    let contentType: String
    let extractionMode: WebExtractionMode
    let bodyText: String
    let links: [WebDocumentLink]
    let byteCount: Int
    let isTruncated: Bool
}

struct WebFetchAttempt: Sendable {
    let url: URL
    let summary: WebFetchSummary?
    let errorDescription: String?
}

struct WebSearchProviderProbeResult: Sendable {
    let providerID: WebSearchProviderID
    let isReachable: Bool
    let latencyMilliseconds: Int
    let statusCode: Int?
    let message: String
}

private struct WebDOMExtractionPayload: Decodable {
    struct Link: Decodable {
        let title: String
        let url: String
    }

    let title: String
    let canonicalURL: String
    let siteName: String
    let author: String
    let publishedAt: String
    let bodyText: String
    let paragraphCount: Int
    let visibleTextLength: Int
    let links: [Link]
}

enum WebURLPolicy {
    static func normalized(rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw AppError.invalidState("不是合法网页 URL：\(rawValue)")
        }
        return try normalized(url)
    }

    static func normalized(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = components.host,
              !rawHost.isEmpty else {
            throw AppError.invalidState("网页 URL 只支持 http/https 且必须包含 host。")
        }
        guard components.user == nil, components.password == nil else {
            throw AppError.invalidState("网页 URL 不允许包含用户名或密码。")
        }

        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !isBlockedHost(host) else {
            throw AppError.invalidState("网页抓取不允许访问本机、私网或链路本地地址。")
        }

        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "http" && components.port == 80) ||
            (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if let items = components.queryItems {
            components.queryItems = items.filter { !isTrackingQueryName($0.name) }
            if components.queryItems?.isEmpty == true {
                components.queryItems = nil
            }
        }
        guard let normalizedURL = components.url else {
            throw AppError.invalidState("网页 URL 规范化失败。")
        }
        return normalizedURL
    }

    static func normalizedKey(for url: URL) throws -> String {
        try normalized(url).absoluteString
    }

    private static func isTrackingQueryName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        if normalized.hasPrefix("utm_") { return true }
        return [
            "gclid", "fbclid", "dclid", "msclkid", "mc_cid", "mc_eid", "_hsenc", "_hsmi"
        ].contains(normalized)
    }

    private static func isBlockedHost(_ host: String) -> Bool {
        if host == "localhost" ||
            host.hasSuffix(".localhost") ||
            host.hasSuffix(".local") {
            return true
        }
        if isBlockedIPv4(host) || isBlockedIPv6(host) {
            return true
        }
        return false
    }

    private static func isBlockedIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              let a = Int(parts[0]), let b = Int(parts[1]),
              let c = Int(parts[2]), let d = Int(parts[3]),
              (0...255).contains(a), (0...255).contains(b),
              (0...255).contains(c), (0...255).contains(d) else {
            return false
        }
        if a == 0 && b == 0 && c == 0 && d == 0 { return true }
        if a == 127 { return true }
        if a == 10 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        return false
    }

    private static func isBlockedIPv6(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "::" || normalized == "::1" { return true }
        if normalized.hasPrefix("fc") || normalized.hasPrefix("fd") { return true }
        if normalized.hasPrefix("fe8") ||
            normalized.hasPrefix("fe9") ||
            normalized.hasPrefix("fea") ||
            normalized.hasPrefix("feb") {
            return true
        }
        return false
    }
}

private final class WebRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              (try? WebURLPolicy.normalized(url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private struct DownloadedWebResource {
    let requestedURL: URL
    let finalURL: URL
    let response: HTTPURLResponse
    let data: Data
    let contentType: String
}

final class WebResearchService {
    private static let maximumBatchFetchURLs = 10
    private static let maximumConcurrentBatchFetches = 10

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeDefaultSession()
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 24
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(
            configuration: configuration,
            delegate: WebRedirectGuard(),
            delegateQueue: nil
        )
    }

    @MainActor
    func search(
        query: String,
        maxResults: Int = 30,
        providerID: WebSearchProviderID = .baidu,
        timeoutSeconds: TimeInterval = 5
    ) async throws -> [WebSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw AppError.invalidState("搜索关键词不能为空。")
        }
        let driver = SearchWebViewDriver()
        return try await driver.search(
            query: trimmedQuery,
            maxResults: maxResults,
            providerID: providerID,
            timeoutSeconds: timeoutSeconds
        )
    }

    func detectSearchProviders(
        providerIDs: [WebSearchProviderID]
    ) async -> [WebSearchProviderProbeResult] {
        await withTaskGroup(of: (Int, WebSearchProviderProbeResult).self) { group in
            for (index, providerID) in providerIDs.enumerated() {
                group.addTask {
                    let startedAt = Date()
                    var request = URLRequest(url: providerID.probeURL)
                    request.httpMethod = "GET"
                    request.timeoutInterval = 6
                    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                    request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")

                    do {
                        let (_, response) = try await self.session.data(for: request)
                        let latency = Int(Date().timeIntervalSince(startedAt) * 1_000)
                        let statusCode = (response as? HTTPURLResponse)?.statusCode
                        let reachable = statusCode.map { (200..<400).contains($0) } ?? true
                        let message = reachable ? "可访问" : "HTTP \(statusCode ?? -1)"
                        return (
                            index,
                            WebSearchProviderProbeResult(
                                providerID: providerID,
                                isReachable: reachable,
                                latencyMilliseconds: latency,
                                statusCode: statusCode,
                                message: message
                            )
                        )
                    } catch {
                        let latency = Int(Date().timeIntervalSince(startedAt) * 1_000)
                        return (
                            index,
                            WebSearchProviderProbeResult(
                                providerID: providerID,
                                isReachable: false,
                                latencyMilliseconds: latency,
                                statusCode: nil,
                                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                            )
                        )
                    }
                }
            }

            var indexedResults: [(Int, WebSearchProviderProbeResult)] = []
            for await result in group {
                indexedResults.append(result)
            }
            return indexedResults.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    @MainActor
    func fetchSummary(
        from url: URL,
        maxBodyCharacters: Int = ReasoningStrengthProfile.fetchStaticWebPageAbsoluteMaxCharacters,
        focus: String? = nil,
        includeLinks: Bool = true,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> WebFetchSummary {
        let resource = try await downloadResource(from: url, timeoutSeconds: timeoutSeconds)
        if resource.contentType == "application/pdf" || resource.finalURL.pathExtension.lowercased() == "pdf" {
            return try extractPDF(resource, maxBodyCharacters: maxBodyCharacters, focus: focus)
        }

        if Self.isHTMLContentType(resource.contentType) {
            return try await extractHTML(
                resource,
                maxBodyCharacters: maxBodyCharacters,
                focus: focus,
                includeLinks: includeLinks,
                timeoutSeconds: timeoutSeconds
            )
        }

        let decoded = try Self.decodeText(
            data: resource.data,
            response: resource.response,
            contentType: resource.contentType
        )
        if Self.isJSONContentType(resource.contentType) {
            return try extractJSON(resource, decodedText: decoded, maxBodyCharacters: maxBodyCharacters, focus: focus)
        }
        if Self.isXMLContentType(resource.contentType) {
            return extractTextLike(resource, decodedText: decoded, mode: .xml, maxBodyCharacters: maxBodyCharacters, focus: focus)
        }
        return extractTextLike(resource, decodedText: decoded, mode: .plainText, maxBodyCharacters: maxBodyCharacters, focus: focus)
    }

    @MainActor
    func fetchSummaries(
        urls: [URL],
        maxBodyCharacters: Int = ReasoningStrengthProfile.fetchStaticWebPageAbsoluteMaxCharacters,
        focus: String? = nil,
        includeLinks: Bool = true,
        maxConcurrentRequests: Int = 4,
        requestTimeoutSeconds: TimeInterval = 12,
        totalTimeoutSeconds: TimeInterval = 12
    ) async -> [WebFetchAttempt] {
        let cappedURLs = Array(urls.prefix(Self.maximumBatchFetchURLs))
        let cappedMaxConcurrentRequests = min(maxConcurrentRequests, Self.maximumConcurrentBatchFetches)
        return await fetchAttempts(
            urls: cappedURLs,
            maxBodyCharacters: maxBodyCharacters,
            focus: focus,
            includeLinks: includeLinks,
            maxConcurrentRequests: cappedMaxConcurrentRequests,
            requestTimeoutSeconds: requestTimeoutSeconds,
            totalTimeoutSeconds: totalTimeoutSeconds
        )
    }

    nonisolated static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/18.0 Safari/605.1.15"

    private static func isTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("timed out") ||
            error.localizedDescription.localizedCaseInsensitiveContains("超时")
    }

    private func downloadResource(
        from requestedURL: URL,
        timeoutSeconds: TimeInterval
    ) async throws -> DownloadedWebResource {
        let normalizedURL = try WebURLPolicy.normalized(requestedURL)
        var request = URLRequest(url: normalizedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "text/html,application/xhtml+xml,application/pdf,text/plain,application/json,application/xml,text/xml;q=0.9,*/*;q=0.5",
            forHTTPHeaderField: "Accept"
        )

        let (temporaryURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.operationFailed("网页服务没有返回有效 HTTP 响应。")
        }
        guard (200...399).contains(httpResponse.statusCode) else {
            throw AppError.operationFailed("网页返回 HTTP \(httpResponse.statusCode)。")
        }
        let finalURL = try WebURLPolicy.normalized(httpResponse.url ?? normalizedURL)
        let contentType = Self.normalizedContentType(response: httpResponse, url: finalURL)
        guard Self.isSupportedContentType(contentType, url: finalURL) else {
            throw AppError.operationFailed("不支持的网页内容类型：\(contentType)。")
        }

        let fileSize = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.size] as? NSNumber
        let byteCount = fileSize?.intValue ?? 0
        let maxBytes = contentType == "application/pdf" ? 24 * 1_024 * 1_024 : 8 * 1_024 * 1_024
        guard byteCount <= maxBytes else {
            throw AppError.operationFailed("下载内容过大：\(byteCount) 字节。")
        }

        let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        return DownloadedWebResource(
            requestedURL: normalizedURL,
            finalURL: finalURL,
            response: httpResponse,
            data: data,
            contentType: contentType
        )
    }

    @MainActor
    private func extractHTML(
        _ resource: DownloadedWebResource,
        maxBodyCharacters: Int,
        focus: String?,
        includeLinks: Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> WebFetchSummary {
        let html = try Self.decodeText(
            data: resource.data,
            response: resource.response,
            contentType: resource.contentType
        )
        let staticPayload = try await WebContentWebViewDriver().extractStaticHTML(
            html,
            baseURL: resource.finalURL,
            focus: focus,
            includeLinks: includeLinks,
            timeoutSeconds: min(timeoutSeconds, 8)
        )
        let needsRendered = Self.shouldRenderHTML(html: html, staticPayload: staticPayload)
        let payload: WebDOMExtractionPayload
        let finalURL: URL
        let mode: WebExtractionMode
        if needsRendered {
            let rendered = try await WebContentWebViewDriver().extractRenderedURL(
                resource.finalURL,
                focus: focus,
                includeLinks: includeLinks,
                timeoutSeconds: min(timeoutSeconds, 12)
            )
            guard rendered.payload.bodyText.count >= 200 else {
                throw AppError.operationFailed("渲染后正文仍不足 200 字符，网页正文提取失败。")
            }
            payload = rendered.payload
            finalURL = try WebURLPolicy.normalized(rendered.finalURL)
            mode = .renderedHTML
        } else {
            payload = staticPayload
            finalURL = resource.finalURL
            mode = .staticHTML
        }

        let projection = Self.projectedBody(payload.bodyText, focus: focus, maxCharacters: maxBodyCharacters)
        return WebFetchSummary(
            requestedURL: resource.requestedURL,
            finalURL: finalURL,
            title: Self.fallbackTitle(payload.title, url: finalURL),
            canonicalURL: Self.normalizedOptionalURL(payload.canonicalURL),
            siteName: Self.nilIfEmpty(payload.siteName),
            author: Self.nilIfEmpty(payload.author),
            publishedAt: Self.nilIfEmpty(payload.publishedAt),
            contentType: resource.contentType,
            extractionMode: mode,
            bodyText: projection.text,
            links: Self.normalizedLinks(payload.links),
            byteCount: resource.data.count,
            isTruncated: projection.isTruncated
        )
    }

    private func extractPDF(
        _ resource: DownloadedWebResource,
        maxBodyCharacters: Int,
        focus: String?
    ) throws -> WebFetchSummary {
        guard let document = PDFDocument(data: resource.data) else {
            throw AppError.operationFailed("PDF 无法解析。")
        }
        var blocks: [String] = []
        for index in 0..<document.pageCount {
            guard let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                continue
            }
            blocks.append("## 第 \(index + 1) 页\n\n\(text)")
        }
        guard !blocks.isEmpty else {
            throw AppError.operationFailed("PDF 没有可提取文本。")
        }
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let projection = Self.projectedBody(blocks.joined(separator: "\n\n"), focus: focus, maxCharacters: maxBodyCharacters)
        return WebFetchSummary(
            requestedURL: resource.requestedURL,
            finalURL: resource.finalURL,
            title: title?.isEmpty == false ? title! : (resource.finalURL.host ?? "PDF"),
            canonicalURL: nil,
            siteName: resource.finalURL.host,
            author: nil,
            publishedAt: nil,
            contentType: resource.contentType,
            extractionMode: .pdf,
            bodyText: projection.text,
            links: [],
            byteCount: resource.data.count,
            isTruncated: projection.isTruncated
        )
    }

    private func extractJSON(
        _ resource: DownloadedWebResource,
        decodedText: String,
        maxBodyCharacters: Int,
        focus: String?
    ) throws -> WebFetchSummary {
        let readableText: String
        if let data = decodedText.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let prettyText = String(data: pretty, encoding: .utf8) {
            readableText = prettyText
        } else {
            readableText = decodedText
        }
        return extractTextLike(
            resource,
            decodedText: readableText,
            mode: .json,
            maxBodyCharacters: maxBodyCharacters,
            focus: focus
        )
    }

    private func extractTextLike(
        _ resource: DownloadedWebResource,
        decodedText: String,
        mode: WebExtractionMode,
        maxBodyCharacters: Int,
        focus: String?
    ) -> WebFetchSummary {
        let normalized = Self.normalizedTextBlocks(decodedText)
        let projection = Self.projectedBody(normalized, focus: focus, maxCharacters: maxBodyCharacters)
        return WebFetchSummary(
            requestedURL: resource.requestedURL,
            finalURL: resource.finalURL,
            title: resource.finalURL.lastPathComponent.isEmpty ? (resource.finalURL.host ?? "文本") : resource.finalURL.lastPathComponent,
            canonicalURL: nil,
            siteName: resource.finalURL.host,
            author: nil,
            publishedAt: nil,
            contentType: resource.contentType,
            extractionMode: mode,
            bodyText: projection.text,
            links: [],
            byteCount: resource.data.count,
            isTruncated: projection.isTruncated
        )
    }

    private func fetchAttempts(
        urls: [URL],
        maxBodyCharacters: Int,
        focus: String?,
        includeLinks: Bool,
        maxConcurrentRequests: Int,
        requestTimeoutSeconds: TimeInterval,
        totalTimeoutSeconds: TimeInterval
    ) async -> [WebFetchAttempt] {
        guard !urls.isEmpty else {
            return []
        }

        let maxConcurrent = min(max(1, maxConcurrentRequests), urls.count)
        var iterator = Array(urls.enumerated()).makeIterator()

        enum FetchEvent: Sendable {
            case attempt(Int, WebFetchAttempt)
            case timeout
        }

        return await withTaskGroup(of: FetchEvent.self) { group in
            var activeFetchCount = 0

            func addNext() {
                guard let (index, url) = iterator.next() else {
                    return
                }
                activeFetchCount += 1
                group.addTask {
                    do {
                        let summary = try await self.fetchSummary(
                            from: url,
                            maxBodyCharacters: maxBodyCharacters,
                            focus: focus,
                            includeLinks: includeLinks,
                            timeoutSeconds: requestTimeoutSeconds
                        )
                        return .attempt(
                            index,
                            WebFetchAttempt(
                                url: url,
                                summary: summary,
                                errorDescription: nil
                            )
                        )
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        return .attempt(
                            index,
                            WebFetchAttempt(
                                url: url,
                                summary: nil,
                                errorDescription: message
                            )
                        )
                    }
                }
            }

            group.addTask {
                let nanoseconds = UInt64(max(0.5, totalTimeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return .timeout
            }

            for _ in 0..<maxConcurrent {
                addNext()
            }

            var indexedAttempts: [(Int, WebFetchAttempt)] = []
            var timedOut = false
            while activeFetchCount > 0 {
                guard let event = await group.next() else {
                    break
                }
                switch event {
                case let .attempt(index, attempt):
                    activeFetchCount -= 1
                    indexedAttempts.append((index, attempt))
                    addNext()
                case .timeout:
                    group.cancelAll()
                    timedOut = true
                    activeFetchCount = 0
                }
            }

            group.cancelAll()
            if timedOut {
                let completed = Set(indexedAttempts.map(\.0))
                for (index, url) in urls.enumerated() where !completed.contains(index) {
                    indexedAttempts.append(
                        (
                            index,
                            WebFetchAttempt(
                                url: url,
                                summary: nil,
                                errorDescription: "超过本次网页浏览总时间上限。"
                            )
                        )
                    )
                }
            }
            return indexedAttempts
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }

    private static func normalizedContentType(response: HTTPURLResponse, url: URL) -> String {
        let mime = response.mimeType?.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if !mime.isEmpty, mime != "application/octet-stream" {
            return mime
        }
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "html", "htm": return "text/html"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "xml": return "application/xml"
        default: return mime.isEmpty ? "application/octet-stream" : mime
        }
    }

    private static func isSupportedContentType(_ contentType: String, url: URL) -> Bool {
        if isHTMLContentType(contentType) || isJSONContentType(contentType) || isXMLContentType(contentType) {
            return true
        }
        if ["application/pdf", "text/plain", "text/markdown"].contains(contentType) {
            return true
        }
        return ["pdf", "html", "htm", "txt", "md", "json", "xml"].contains(url.pathExtension.lowercased())
    }

    private static func isHTMLContentType(_ contentType: String) -> Bool {
        contentType == "text/html" || contentType == "application/xhtml+xml"
    }

    private static func isJSONContentType(_ contentType: String) -> Bool {
        contentType == "application/json" || contentType == "application/ld+json"
    }

    private static func isXMLContentType(_ contentType: String) -> Bool {
        ["application/xml", "text/xml", "application/rss+xml", "application/atom+xml"].contains(contentType)
    }

    private static func decodeText(
        data: Data,
        response: HTTPURLResponse,
        contentType: String
    ) throws -> String {
        var encodings: [String.Encoding] = []
        if let encodingName = response.textEncodingName,
           let encoding = stringEncoding(ianaName: encodingName) {
            encodings.append(encoding)
        }
        if isHTMLContentType(contentType) {
            let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
            if let charset = firstMatch(pattern: #"<meta[^>]+charset\s*=\s*["']?\s*([A-Za-z0-9._-]+)"#, in: prefix),
               let encoding = stringEncoding(ianaName: charset) {
                encodings.append(encoding)
            }
            if let charset = firstMatch(pattern: #"content\s*=\s*["'][^"']*charset\s*=\s*([A-Za-z0-9._-]+)"#, in: prefix),
               let encoding = stringEncoding(ianaName: charset) {
                encodings.append(encoding)
            }
        }
        encodings.append(.utf8)
        encodings.append(
            String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        )
        encodings.append(String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))))
        encodings.append(.isoLatin1)

        var seen: Set<UInt> = []
        for encoding in encodings where seen.insert(encoding.rawValue).inserted {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw AppError.operationFailed("网页文本解码失败，无法确定字符集。")
    }

    private static func stringEncoding(ianaName: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return nil
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    private static func shouldRenderHTML(html: String, staticPayload: WebDOMExtractionPayload) -> Bool {
        if staticPayload.bodyText.count < 600 { return true }
        if staticPayload.paragraphCount < 2 && html.count > 50_000 { return true }
        if staticPayload.bodyText.count < 2_000 {
            let markers = [
                #"id="__next""#, #"id="root""#, #"id="app""#, "__NEXT_DATA__",
                "hydrateRoot", "webpackJsonp", "data-reactroot"
            ]
            return markers.contains { html.contains($0) }
        }
        return false
    }

    private static func projectedBody(
        _ body: String,
        focus: String?,
        maxCharacters: Int
    ) -> (text: String, isTruncated: Bool) {
        let cappedMax = min(max(1, maxCharacters), ReasoningStrengthProfile.fetchStaticWebPageAbsoluteMaxCharacters)
        let normalizedFocus = focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidate: String
        if normalizedFocus.isEmpty {
            candidate = body
        } else {
            let blocks = body.components(separatedBy: "\n\n")
            let words = normalizedFocus
                .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
            var selected: Set<Int> = []
            for (index, block) in blocks.enumerated() {
                let lower = block.lowercased()
                var score = 0
                if lower.contains(normalizedFocus.lowercased()) { score += 20 }
                for word in words where lower.contains(word.lowercased()) {
                    score += 3
                }
                if block.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") {
                    score += 2
                }
                if score > 0 {
                    selected.insert(max(0, index - 1))
                    selected.insert(index)
                    selected.insert(min(blocks.count - 1, index + 1))
                }
            }
            candidate = selected.isEmpty
                ? body
                : selected.sorted().map { blocks[$0] }.joined(separator: "\n\n")
        }
        let truncated = candidate.count > cappedMax
        return (String(candidate.prefix(cappedMax)), truncated)
    }

    private static func normalizedTextBlocks(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var output: [String] = []
        var blankCount = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                blankCount += 1
                if blankCount <= 2 {
                    output.append("")
                }
            } else {
                blankCount = 0
                output.append(trimmed)
            }
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackTitle(_ title: String, url: URL) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (url.host ?? "网页") : trimmed
    }

    private static func nilIfEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedOptionalURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try? WebURLPolicy.normalized(rawValue: trimmed)
    }

    private static func normalizedLinks(_ links: [WebDOMExtractionPayload.Link]) -> [WebDocumentLink] {
        var seen: Set<String> = []
        var output: [WebDocumentLink] = []
        for link in links {
            guard let url = try? WebURLPolicy.normalized(rawValue: link.url),
                  let key = try? WebURLPolicy.normalizedKey(for: url),
                  !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            let title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
            output.append(WebDocumentLink(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url))
            if output.count >= 30 {
                break
            }
        }
        return output
    }
}

struct PalmiBrowserScreen: View {
    let options: SafariPresentationOptions
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var sharePayload: SharePayload?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                PalmiWebBrowserView(options: options)
                    .ignoresSafeArea()

                browserChrome(safeAreaTop: proxy.safeAreaInsets.top)
            }
            .background(Color(.systemBackground))
            .ignoresSafeArea()
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: [payload.url])
        }
    }

    private var title: String {
        let trimmedTitle = options.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        if options.url.isFileURL {
            let filename = options.url.deletingPathExtension().lastPathComponent
            return filename.isEmpty ? options.url.lastPathComponent : filename
        }

        return options.url.host ?? "网页"
    }

    private func browserChrome(safeAreaTop: CGFloat) -> some View {
        GlassEffectContainer(spacing: 16) {
            ZStack {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 210)
                    .glassEffect(.regular, in: .capsule)

                HStack {
                    browserChromeButton(systemImage: "chevron.left", accessibilityLabel: "返回") {
                        onClose?()
                        dismiss()
                    }

                    Spacer()

                    browserChromeButton(systemImage: "square.and.arrow.up", accessibilityLabel: "分享网页") {
                        sharePayload = SharePayload(url: options.url)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, safeAreaTop + 8)
        }
    }

    private func browserChromeButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SafariSheet: View {
    let options: SafariPresentationOptions

    var body: some View {
        if Self.canUseSafariViewController(for: options.url) {
            SafariViewControllerSheet(options: options)
        } else {
            PalmiWebBrowserView(options: options)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private static func canUseSafariViewController(for url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

private struct SafariViewControllerSheet: UIViewControllerRepresentable {
    let options: SafariPresentationOptions

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = options.entersReaderIfAvailable
        configuration.barCollapsingEnabled = options.barCollapsingEnabled
        return SFSafariViewController(url: options.url, configuration: configuration)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct PalmiWebBrowserView: UIViewRepresentable {
    let options: SafariPresentationOptions

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        if let readAccessURL = options.fileReadAccessURL {
            configuration.setURLSchemeHandler(
                PalmiLocalFileSchemeHandler(readAccessURL: readAccessURL),
                forURLScheme: PalmiLocalFileScheme.scheme
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        load(options.url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let loadKey = BrowserLoadKey(url: options.url, readAccessURL: options.fileReadAccessURL)
        guard context.coordinator.loadedKey != loadKey else { return }
        load(options.url, in: webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedKey = nil
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        uiView.loadHTMLString("", baseURL: nil)
    }

    private func load(_ url: URL, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedKey = BrowserLoadKey(url: url, readAccessURL: options.fileReadAccessURL)
        webView.stopLoading()

        if url.isFileURL, let readAccessURL = options.fileReadAccessURL {
            let browserURL = PalmiLocalFileScheme.url(for: url, readAccessURL: readAccessURL) ?? url
            webView.load(URLRequest(url: browserURL))
        } else if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    struct BrowserLoadKey: Equatable {
        let url: URL
        let readAccessURL: URL?
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedKey: BrowserLoadKey?

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

private enum PalmiLocalFileScheme {
    static let scheme = "palmi-local"
    static let host = "workspace"

    static func url(for fileURL: URL, readAccessURL: URL) -> URL? {
        guard fileURL.isFileURL,
              let relativePath = relativePath(for: fileURL, in: readAccessURL) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + relativePath
        return components.url
    }

    static func fileURL(for url: URL, readAccessURL: URL) -> URL? {
        guard url.scheme == scheme, url.host == host else { return nil }

        let relativePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else { return nil }

        let candidate = readAccessURL.appendingPathComponent(relativePath)
        let standardizedRoot = readAccessURL.standardizedFileURL.resolvingSymlinksInPath()
        let standardizedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : standardizedRoot.path + "/"
        guard standardizedCandidate.path.hasPrefix(rootPath) else { return nil }
        return standardizedCandidate
    }

    static func relativePath(for fileURL: URL, in readAccessURL: URL) -> String? {
        let standardizedRoot = readAccessURL.standardizedFileURL.resolvingSymlinksInPath()
        let standardizedFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : standardizedRoot.path + "/"
        guard standardizedFile.path.hasPrefix(rootPath) else { return nil }
        return String(standardizedFile.path.dropFirst(rootPath.count))
    }
}

private final class PalmiLocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    private let readAccessURL: URL

    init(readAccessURL: URL) {
        self.readAccessURL = readAccessURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let fileURL = PalmiLocalFileScheme.fileURL(for: requestURL, readAccessURL: readAccessURL) else {
            urlSchemeTask.didFailWithError(Self.error(code: 400, message: "Invalid local file URL."))
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            urlSchemeTask.didFailWithError(Self.error(code: 404, message: "Local file not found."))
            return
        }

        do {
            var data = try Data(contentsOf: fileURL)
            let mimeType = Self.mimeType(for: fileURL)
            if Self.shouldRewriteLocalReferences(in: fileURL, mimeType: mimeType),
               let html = String(data: data, encoding: .utf8) {
                data = Data(Self.rewriteLocalFileReferences(in: html, readAccessURL: readAccessURL).utf8)
            }

            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mimeType,
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "no-store"
                ]
            ) ?? URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func shouldRewriteLocalReferences(in fileURL: URL, mimeType: String) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        return mimeType == "text/html" || ext == "html" || ext == "htm"
    }

    private static func rewriteLocalFileReferences(in html: String, readAccessURL: URL) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"file://[^"'\s<>)]+"#) else {
            return html
        }

        var output = html
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let rawURLString = String(output[range])
            guard let fileURL = URL(string: rawURLString),
                  let localURL = PalmiLocalFileScheme.url(for: fileURL, readAccessURL: readAccessURL) else {
                continue
            }
            output.replaceSubrange(range, with: localURL.absoluteString)
        }
        return output
    }

    private static func mimeType(for fileURL: URL) -> String {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js", "mjs":
            return "text/javascript; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        default:
            return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    private static func error(code: Int, message: String) -> NSError {
        NSError(
            domain: "PalmiLocalFileSchemeHandler",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

@MainActor
private final class WebContentWebViewDriver: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?

    func extractStaticHTML(
        _ html: String,
        baseURL: URL,
        focus: String?,
        includeLinks: Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> WebDOMExtractionPayload {
        let webView = makeWebView(allowsJavaScript: false)
        self.webView = webView
        defer { cleanup() }
        try await load(timeoutSeconds: timeoutSeconds) {
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        try await waitForStableBodyText(maxWaitSeconds: 0.75)
        return try await extractPayload(focus: focus, includeLinks: includeLinks)
    }

    func extractRenderedURL(
        _ url: URL,
        focus: String?,
        includeLinks: Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> (payload: WebDOMExtractionPayload, finalURL: URL) {
        let normalizedURL = try WebURLPolicy.normalized(url)
        let webView = makeWebView(allowsJavaScript: true)
        self.webView = webView
        defer { cleanup() }
        try await load(timeoutSeconds: timeoutSeconds) {
            webView.load(URLRequest(url: normalizedURL))
        }
        try await waitForStableBodyText(maxWaitSeconds: 2)
        let finalURL = try WebURLPolicy.normalized(webView.url ?? normalizedURL)
        return (try await extractPayload(focus: focus, includeLinks: includeLinks), finalURL)
    }

    private func makeWebView(allowsJavaScript: Bool) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        webView.customUserAgent = WebResearchService.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }

    private func load(timeoutSeconds: TimeInterval, start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            loadTimeoutTask?.cancel()
            loadTimeoutTask = Task { [weak self] in
                let nanoseconds = UInt64(max(0.5, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                await MainActor.run {
                    self?.finishLoad(.failure(AppError.operationFailed("网页加载超时。")))
                }
            }
            start()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame == true || navigationAction.targetFrame == nil {
            if let url = navigationAction.request.url,
               (try? WebURLPolicy.normalized(url)) == nil,
               url.scheme != "about" {
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else { return }
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        loadContinuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            webView?.stopLoading()
            continuation.resume(throwing: error)
        }
    }

    private func waitForStableBodyText(maxWaitSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        var previousLength: Int?
        while Date() < deadline {
            let raw = try await webView?.evaluateJavaScriptString("""
            String((document.body && document.body.innerText) ? document.body.innerText.length : 0)
            """) ?? "0"
            let currentLength = Int(raw) ?? 0
            if previousLength == currentLength {
                return
            }
            previousLength = currentLength
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func extractPayload(focus: String?, includeLinks: Bool) async throws -> WebDOMExtractionPayload {
        guard let webView else {
            throw AppError.invalidState("网页视图未初始化。")
        }
        let script = Self.extractionScript(
            focus: focus ?? "",
            includeLinks: includeLinks
        )
        let raw = try await webView.evaluateJavaScriptString(script)
        let data = Data(raw.utf8)
        return try JSONDecoder().decode(WebDOMExtractionPayload.self, from: data)
    }

    private func cleanup() {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        loadContinuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
        webView = nil
    }

    private static func extractionScript(focus: String, includeLinks: Bool) -> String {
        let focusLiteral = String(reflecting: focus)
        return """
        (() => {
          const focus = \(focusLiteral);
          const includeLinks = \(includeLinks ? "true" : "false");
          const normalize = (text) => (text || '').replace(/\\s+/g, ' ').trim();
          const attrText = (el) => el ? ((el.getAttribute('content') || el.getAttribute('datetime') || el.textContent || '').trim()) : '';
          const pick = (selectors) => {
            for (const selector of selectors) {
              const value = attrText(document.querySelector(selector));
              if (value) return value;
            }
            return '';
          };
          const noisy = ['cookie','consent','advert','advertisement','share','social','sidebar','recommend','related','newsletter','popup','modal','toolbar','breadcrumb','pagination'];
          document.querySelectorAll('script,style,noscript,template,svg,canvas,iframe,object,embed,form,nav,header,footer,aside,dialog,[hidden],[aria-hidden="true"],[role="navigation"],[role="banner"],[role="complementary"]').forEach((el) => el.remove());
          Array.from(document.querySelectorAll('body *')).forEach((el) => {
            const marker = ((el.id || '') + ' ' + (el.className || '')).toLowerCase();
            if (noisy.some((word) => marker.includes(word))) el.remove();
          });
          const title = pick(['meta[property="og:title"]','meta[name="twitter:title"]','h1']) || document.title || '';
          const canonicalURL = document.querySelector('link[rel="canonical"]')?.href || '';
          const siteName = pick(['meta[property="og:site_name"]']);
          const author = pick(['meta[name="author"]','meta[property="article:author"]','meta[name="byl"]']);
          const publishedAt = pick(['meta[property="article:published_time"]','meta[name="date"]','meta[name="publishdate"]','meta[itemprop="datePublished"]','time[datetime]']);
          const selectors = ['article','main','[role="main"]','.article','.article-content','.post','.post-content','.entry-content','#content','.content','section','div'];
          const positive = ['article','content','entry','main','post','story','body'];
          const negative = ['comment','footer','header','nav','sidebar','related','recommend','share','social','promo','advert'];
          const focusWords = focus.toLowerCase().split(/[\\s,，。.!?！？;；:：、]+/).filter((word) => word.length >= 2);
          let best = null;
          for (const el of Array.from(document.querySelectorAll(selectors.join(',')))) {
            const text = normalize(el.innerText);
            const textLength = text.length;
            if (textLength < 200) continue;
            const linkTextLength = Array.from(el.querySelectorAll('a')).reduce((sum, a) => sum + normalize(a.innerText).length, 0);
            const linkDensity = linkTextLength / Math.max(textLength, 1);
            if (linkDensity > 0.65) continue;
            const paragraphCount = Array.from(el.querySelectorAll('p')).filter((p) => normalize(p.innerText).length > 0).length;
            const headingCount = el.querySelectorAll('h1,h2,h3,h4,h5,h6').length;
            const listItemCount = el.querySelectorAll('li').length;
            const preCount = el.querySelectorAll('pre').length;
            const punctuationCount = (text.match(/[。！？；：，、.!?;:,]/g) || []).length;
            const marker = ((el.id || '') + ' ' + (el.className || '')).toLowerCase();
            const semanticBonus = (el.matches('article,main,[role="main"]') ? 800 : 0);
            const positiveClassBonus = positive.some((word) => marker.includes(word)) ? 500 : 0;
            const negativeClassPenalty = negative.some((word) => marker.includes(word)) ? 1200 : 0;
            const lower = text.toLowerCase();
            let focusBonus = 0;
            if (focus && lower.includes(focus.toLowerCase())) focusBonus += 500;
            for (const word of focusWords) if (lower.includes(word)) focusBonus += 100;
            const score = textLength + paragraphCount * 120 + headingCount * 80 + listItemCount * 40 + preCount * 120 + punctuationCount * 8 + semanticBonus + positiveClassBonus + focusBonus - linkDensity * textLength * 1.5 - negativeClassPenalty;
            if (!best || score > best.score) best = { el, score };
          }
          const root = best ? best.el : document.body;
          const blocks = [];
          const push = (text) => { const value = normalize(text); if (value) blocks.push(value); };
          const walk = (node) => {
            if (!node) return;
            if (node.nodeType === Node.TEXT_NODE) return;
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            const tag = node.tagName.toLowerCase();
            if (/^h[1-6]$/.test(tag)) { blocks.push(`${'#'.repeat(Number(tag[1]))} ${normalize(node.innerText)}`); return; }
            if (tag === 'li') { push(`- ${node.innerText}`); return; }
            if (tag === 'blockquote') { blocks.push(normalize(node.innerText).split('\\n').map((line) => `> ${line}`).join('\\n')); return; }
            if (tag === 'pre') { blocks.push('```\\n' + (node.innerText || '').trim() + '\\n```'); return; }
            if (tag === 'table') {
              Array.from(node.querySelectorAll('tr')).forEach((tr) => blocks.push(Array.from(tr.children).map((cell) => normalize(cell.innerText)).join(' | ')));
              return;
            }
            if (['p','div','section','article'].includes(tag)) {
              const childBlocksBefore = blocks.length;
              Array.from(node.children).forEach(walk);
              if (blocks.length === childBlocksBefore) push(node.innerText);
              return;
            }
            if (tag === 'br') { blocks.push('\\n'); return; }
            Array.from(node.children).forEach(walk);
          };
          Array.from(root.children).forEach(walk);
          let bodyText = blocks.join('\\n\\n').replace(/\\n{3,}/g, '\\n\\n').trim();
          if (!bodyText) bodyText = normalize(root.innerText);
          const paragraphCount = Array.from(root.querySelectorAll('p')).filter((p) => normalize(p.innerText).length > 0).length;
          const links = includeLinks ? Array.from(root.querySelectorAll('a[href]')).slice(0, 60).map((a) => ({ title: normalize(a.innerText) || (new URL(a.href, document.baseURI)).host, url: (new URL(a.href, document.baseURI)).href })).filter((link) => /^https?:/i.test(link.url)) : [];
          return JSON.stringify({ title, canonicalURL, siteName, author, publishedAt, bodyText, paragraphCount, visibleTextLength: document.body?.innerText?.length || 0, links });
        })()
        """
    }
}

@MainActor
private final class SearchWebViewDriver: NSObject, WKNavigationDelegate, WKUIDelegate {
    private struct SearchPayload: Decodable {
        struct Entry: Decodable {
            let title: String
            let url: String
            let snippet: String
        }
        let results: [Entry]
    }

    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        webView.customUserAgent = WebResearchService.userAgent
        self.webView = webView
        super.init()
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
    }

    func search(
        query: String,
        maxResults: Int,
        providerID: WebSearchProviderID,
        timeoutSeconds: TimeInterval
    ) async throws -> [WebSearchResult] {
        let requested = min(max(1, maxResults), 50)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var collected: [WebSearchResult] = []
        var seen: Set<String> = []

        for pageIndex in 0..<5 {
            guard collected.count < requested else { break }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let searchURL = try searchURL(providerID: providerID, query: query, pageIndex: pageIndex)
            try await load(URLRequest(url: searchURL), timeoutSeconds: remaining)
            try await waitForStableBodyText(maxWaitSeconds: 1)
            let raw = try await webView.evaluateJavaScriptString(Self.extractionScript(providerID: providerID))
            let payload = try JSONDecoder().decode(SearchPayload.self, from: Data(raw.utf8))
            var pageHadNewResult = false
            for entry in payload.results {
                guard let url = normalizedResultURL(entry.url, providerID: providerID, baseURL: searchURL),
                      let key = try? WebURLPolicy.normalizedKey(for: url),
                      !seen.contains(key),
                      Self.isUsefulTitle(entry.title) else {
                    continue
                }
                seen.insert(key)
                pageHadNewResult = true
                collected.append(
                    WebSearchResult(
                        title: String(Self.normalizedWhitespace(entry.title).prefix(200)),
                        url: url,
                        snippet: String(Self.normalizedWhitespace(entry.snippet).prefix(320))
                    )
                )
                if collected.count >= requested {
                    break
                }
            }
            if !pageHadNewResult {
                break
            }
        }
        return Array(collected.prefix(requested))
    }

    private func searchURL(providerID: WebSearchProviderID, query: String, pageIndex: Int) throws -> URL {
        var components: URLComponents
        switch providerID {
        case .baidu:
            components = URLComponents(string: "https://www.baidu.com/s")!
            components.queryItems = [
                URLQueryItem(name: "wd", value: query),
                URLQueryItem(name: "pn", value: String(pageIndex * 10))
            ]
        case .bing:
            components = URLComponents(string: "https://www.bing.com/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "first", value: String(pageIndex * 10 + 1))
            ]
        case .duckDuckGo:
            components = URLComponents(string: "https://duckduckgo.com/html/")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "s", value: String(pageIndex * 30))
            ]
        case .sogou:
            components = URLComponents(string: "https://www.sogou.com/web")!
            components.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "page", value: String(pageIndex + 1))
            ]
        case .so360:
            components = URLComponents(string: "https://www.so.com/s")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "pn", value: String(pageIndex + 1))
            ]
        }
        guard let url = components.url else {
            throw AppError.invalidState("搜索 URL 生成失败。")
        }
        return url
    }

    private func load(_ request: URLRequest, timeoutSeconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            loadTimeoutTask?.cancel()
            loadTimeoutTask = Task { [weak self] in
                let nanoseconds = UInt64(max(0.5, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                await MainActor.run {
                    self?.finishLoad(.failure(AppError.operationFailed("搜索超时，已返回当前可用结果。")))
                }
            }
            webView.load(request)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else { return }
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        loadContinuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            webView.stopLoading()
            continuation.resume(throwing: error)
        }
    }

    private func waitForStableBodyText(maxWaitSeconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        var previousLength: Int?
        while Date() < deadline {
            let raw = try await webView.evaluateJavaScriptString("""
            String((document.body && document.body.innerText) ? document.body.innerText.length : 0)
            """)
            let currentLength = Int(raw) ?? 0
            if previousLength == currentLength {
                return
            }
            previousLength = currentLength
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func normalizedResultURL(_ rawValue: String, providerID: WebSearchProviderID, baseURL: URL) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let candidate = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }
        if providerID == .duckDuckGo,
           candidate.host?.contains("duckduckgo.com") == true,
           candidate.path == "/l/",
           let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let url = try? WebURLPolicy.normalized(rawValue: target) {
            return url
        }
        if providerID == .bing,
           candidate.path == "/ck/a",
           let components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
           let encoded = components.queryItems?.first(where: { $0.name == "u" })?.value,
           let url = decodeBingRedirect(encoded).flatMap({ try? WebURLPolicy.normalized(rawValue: $0) }) {
            return url
        }
        return try? WebURLPolicy.normalized(candidate)
    }

    private func decodeBingRedirect(_ value: String) -> String? {
        var encoded = value
        if encoded.hasPrefix("a1") {
            encoded.removeFirst(2)
        }
        encoded = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 {
            encoded.append("=")
        }
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    private static func isUsefulTitle(_ title: String) -> Bool {
        let normalized = normalizedWhitespace(title)
        guard normalized.count >= 2, normalized.count <= 200 else {
            return false
        }
        let noise = ["登录", "设置", "下一页", "图片", "视频", "sign in", "settings", "images", "videos"]
        return !noise.contains { normalized.localizedCaseInsensitiveContains($0) && normalized.count <= 12 }
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func extractionScript(providerID: WebSearchProviderID) -> String {
        let selectors: (container: String, title: String, snippet: String)
        switch providerID {
        case .baidu:
            selectors = ("[mu], .result, .result-op, .c-container, .c-result", "h3 a", ".c-abstract, .content-right_8Zs40, .c-span-last")
        case .bing:
            selectors = ("li.b_algo", "h2 a", ".b_caption p, .b_snippet")
        case .duckDuckGo:
            selectors = (".result, .web-result", ".result__a, h2 a", ".result__snippet")
        case .sogou:
            selectors = (".vrwrap, .rb, .results > div", "h3 a", ".str-text-info, .ft, .text-layout")
        case .so360:
            selectors = (".res-list, .result", "h3 a", ".res-desc, .summary")
        }
        return """
        (() => {
          const normalize = (text) => (text || '').replace(/\\s+/g, ' ').trim();
          const containers = Array.from(document.querySelectorAll('\(selectors.container)'));
          const fallbackContainers = containers.length ? containers : Array.from(document.querySelectorAll('article, li, .result, .res-list, .web-result'));
          const results = [];
          for (const container of fallbackContainers) {
            const anchor = container.querySelector('\(selectors.title)') || container.querySelector('h2 a, h3 a');
            if (!anchor) continue;
            const title = normalize(anchor.textContent);
            const snippet = normalize(container.querySelector('\(selectors.snippet)')?.innerText || container.innerText || '').slice(0, 320);
            const url = container.getAttribute('mu') || anchor.href || '';
            if (!title || !url) continue;
            results.push({ title, url, snippet });
          }
          return JSON.stringify({ results });
        })()
        """
    }
}

@MainActor
private extension WKWebView {
    func evaluateJavaScriptString(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let string = value as? String else {
                    continuation.resume(throwing: AppError.invalidState("网页脚本没有返回字符串结果。"))
                    return
                }
                continuation.resume(returning: string)
            }
        }
    }
}
