import Foundation
import SafariServices
import SwiftUI
import WebKit

struct WebSearchResult: Sendable {
    let title: String
    let url: URL
    let snippet: String
}

struct WebFetchSummary: Sendable {
    let title: String
    let url: URL
    let bodyText: String
    let byteCount: Int
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

final class WebResearchService {
    private static let maximumBatchFetchURLs = 10
    private static let maximumConcurrentBatchFetches = 10

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeDefaultSession()
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
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
        switch providerID {
        case .baidu:
            let driver = BaiduSearchWebViewDriver()
            return try await driver.search(query: trimmedQuery, maxResults: maxResults, timeoutSeconds: timeoutSeconds)
        case .bing, .duckDuckGo, .sogou, .so360:
            do {
                return try await searchHTML(
                    query: trimmedQuery,
                    maxResults: maxResults,
                    providerID: providerID,
                    timeoutSeconds: timeoutSeconds
                )
            } catch {
                if Self.isTimeout(error) {
                    return []
                }
                throw error
            }
        }
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

    func fetchSummary(
        from url: URL,
        maxBodyCharacters: Int = 500,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> WebFetchSummary {
        let (html, byteCount) = try await loadHTML(from: url, timeoutSeconds: timeoutSeconds)
        let title = Self.extractTitle(from: html) ?? url.host ?? "网页"
        let plainText = Self.extractBodyText(from: html, maxBodyCharacters: maxBodyCharacters)
        return WebFetchSummary(title: title, url: url, bodyText: plainText, byteCount: byteCount)
    }

    func fetchSummaries(
        urls: [URL],
        maxBodyCharacters: Int = 500,
        maxConcurrentRequests: Int = 4,
        requestTimeoutSeconds: TimeInterval = 12,
        totalTimeoutSeconds: TimeInterval = 12
    ) async -> [WebFetchAttempt] {
        let cappedURLs = Array(urls.prefix(Self.maximumBatchFetchURLs))
        let cappedMaxConcurrentRequests = min(maxConcurrentRequests, Self.maximumConcurrentBatchFetches)
        return await fetchAttempts(
            urls: cappedURLs,
            maxBodyCharacters: maxBodyCharacters,
            maxConcurrentRequests: cappedMaxConcurrentRequests,
            requestTimeoutSeconds: requestTimeoutSeconds,
            totalTimeoutSeconds: totalTimeoutSeconds
        )
    }

    nonisolated private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static func isTimeout(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("timed out") ||
            error.localizedDescription.localizedCaseInsensitiveContains("超时")
    }

    private func loadHTML(
        from url: URL,
        timeoutSeconds: TimeInterval = 15
    ) async throws -> (html: String, byteCount: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        return (String(decoding: data, as: UTF8.self), data.count)
    }

    private func searchHTML(
        query: String,
        maxResults: Int,
        providerID: WebSearchProviderID,
        timeoutSeconds: TimeInterval
    ) async throws -> [WebSearchResult] {
        let searchURL = try providerID.searchURL(query: query)
        let (html, _) = try await loadHTML(from: searchURL, timeoutSeconds: timeoutSeconds)
        let results = Self.extractSearchResults(
            from: html,
            providerID: providerID,
            searchURL: searchURL,
            maxResults: maxResults
        )
        if results.isEmpty {
            throw AppError.operationFailed("\(providerID.title) 没有解析到可用搜索结果。")
        }
        return results
    }

    nonisolated private static func extractTitle(from html: String) -> String? {
        guard
            let range = html.range(of: "<title[^>]*>(.*?)</title>", options: .regularExpression)
        else {
            return nil
        }
        return String(html[range])
            .replacingOccurrences(of: "<title>", with: "")
            .replacingOccurrences(of: "</title>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func extractBodyText(from html: String, maxBodyCharacters: Int) -> String {
        let noScripts = html.replacingOccurrences(
            of: "<script[\\s\\S]*?</script>|<style[\\s\\S]*?</style>",
            with: " ",
            options: .regularExpression
        )
        let noTags = noScripts.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let normalized = noTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(decodeHTMLEntities(normalized).prefix(max(1, maxBodyCharacters)))
    }

    nonisolated private static func cleanupHTMLText(_ text: String) -> String {
        let noTags = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = decodeHTMLEntities(noTags)
        return decoded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    nonisolated private static func extractSearchResults(
        from html: String,
        providerID: WebSearchProviderID,
        searchURL: URL,
        maxResults: Int
    ) -> [WebSearchResult] {
        let pattern = #"<a\s+[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: nsRange)
        var results: [WebSearchResult] = []
        var seenURLs: Set<String> = []

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else {
                continue
            }

            let rawHref = String(html[hrefRange])
            let rawTitle = String(html[titleRange])
            let title = cleanupHTMLText(rawTitle)
            guard isUsefulSearchTitle(title) else { continue }

            guard let url = normalizedSearchResultURL(
                rawHref,
                providerID: providerID,
                baseURL: searchURL
            ) else {
                continue
            }

            guard shouldKeepSearchResultURL(url, providerID: providerID) else {
                continue
            }

            let key = url.absoluteString
            guard !seenURLs.contains(key) else { continue }
            seenURLs.insert(key)

            let snippet = nearbySnippet(
                in: html,
                matchRange: match.range,
                title: title
            )
            results.append(
                WebSearchResult(
                    title: title,
                    url: url,
                    snippet: snippet
                )
            )

            if results.count >= max(1, maxResults) {
                break
            }
        }

        return results
    }

    nonisolated private static func normalizedSearchResultURL(
        _ rawHref: String,
        providerID: WebSearchProviderID,
        baseURL: URL
    ) -> URL? {
        let decodedHref = decodeHTMLEntities(rawHref)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decodedHref.isEmpty,
              !decodedHref.hasPrefix("#"),
              !decodedHref.lowercased().hasPrefix("javascript:") else {
            return nil
        }

        let candidateURL = URL(string: decodedHref, relativeTo: baseURL)?.absoluteURL
        guard let candidateURL else { return nil }

        if providerID == .duckDuckGo,
           candidateURL.host?.contains("duckduckgo.com") == true,
           candidateURL.path == "/l/",
           let components = URLComponents(url: candidateURL, resolvingAgainstBaseURL: false),
           let encodedTarget = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let target = encodedTarget.removingPercentEncoding,
           let targetURL = URL(string: target) {
            return targetURL
        }

        return candidateURL
    }

    nonisolated private static func shouldKeepSearchResultURL(
        _ url: URL,
        providerID: WebSearchProviderID
    ) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else {
            return false
        }

        let blockedHosts = [
            "www.bing.com", "cn.bing.com", "bing.com",
            "duckduckgo.com", "www.duckduckgo.com",
            "www.baidu.com", "baidu.com"
        ]
        if blockedHosts.contains(host), providerID != .sogou, providerID != .so360 {
            return false
        }

        return true
    }

    nonisolated private static func isUsefulSearchTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 160 else {
            return false
        }

        let noise = [
            "登录", "设置", "新闻", "图片", "视频", "地图", "更多",
            "下一页", "上一页", "反馈", "隐私", "条款",
            "sign in", "settings", "images", "videos", "maps", "news"
        ]
        return !noise.contains { trimmed.localizedCaseInsensitiveContains($0) && trimmed.count <= 8 }
    }

    nonisolated private static func nearbySnippet(
        in html: String,
        matchRange: NSRange,
        title: String
    ) -> String {
        guard let range = Range(matchRange, in: html) else { return "" }
        let tail = html[range.upperBound...].prefix(420)
        let snippet = cleanupHTMLText(String(tail))
            .replacingOccurrences(of: title, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(snippet.prefix(220))
    }

    private func fetchAttempts(
        urls: [URL],
        maxBodyCharacters: Int,
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
                    activeFetchCount = 0
                }
            }

            group.cancelAll()
            return indexedAttempts
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }
    }
}

struct SafariSheet: UIViewControllerRepresentable {
    let options: SafariPresentationOptions

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = options.entersReaderIfAvailable
        configuration.barCollapsingEnabled = options.barCollapsingEnabled
        return SFSafariViewController(url: options.url, configuration: configuration)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

@MainActor
private final class BaiduSearchWebViewDriver: NSObject, WKNavigationDelegate {
    private static let maxSearchResults = 50
    private static let pageSize = 10

    private struct SearchPayload: Decodable {
        let title: String
        let results: [SearchEntry]
    }

    private struct SearchEntry: Decodable {
        let title: String
        let url: String
        let snippet: String
    }

    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
        self.webView = webView

        super.init()
        self.webView.navigationDelegate = self
    }

    func search(query: String, maxResults: Int, timeoutSeconds: TimeInterval) async throws -> [WebSearchResult] {
        let requestedResults = min(max(1, maxResults), Self.maxSearchResults)
        let pageCount = max(1, Int(ceil(Double(requestedResults) / Double(Self.pageSize))))
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var collected: [WebSearchResult] = []
        var seenURLs: Set<String> = []

        for pageIndex in 0..<pageCount {
            let remainingSeconds = deadline.timeIntervalSinceNow
            guard remainingSeconds > 0 else {
                break
            }

            do {
                let pageResults = try await searchPage(
                    query: query,
                    offset: pageIndex * Self.pageSize,
                    timeoutSeconds: remainingSeconds
                )
                for result in pageResults {
                    let key = result.url.absoluteString
                    guard !seenURLs.contains(key) else { continue }
                    seenURLs.insert(key)
                    collected.append(result)
                    if collected.count >= requestedResults {
                        return Array(collected.prefix(requestedResults))
                    }
                }

                if pageResults.isEmpty {
                    break
                }
            } catch {
                if Self.isSearchTimeout(error) {
                    break
                }
                if collected.isEmpty {
                    throw error
                }
                break
            }
        }

        return Array(collected.prefix(requestedResults))
    }

    private func searchPage(
        query: String,
        offset: Int,
        timeoutSeconds: TimeInterval
    ) async throws -> [WebSearchResult] {
        var components = URLComponents(string: "https://www.baidu.com/s")!
        components.queryItems = [
            URLQueryItem(name: "wd", value: query),
            URLQueryItem(name: "ie", value: "utf-8"),
            URLQueryItem(name: "pn", value: String(max(0, offset)))
        ]
        guard let url = components.url else {
            throw AppError.invalidState("百度搜索 URL 生成失败。")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        request.setValue("zh-CN,zh;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")

        try await load(request, timeoutSeconds: timeoutSeconds)

        if webView.url?.host?.contains("wappass.baidu.com") == true {
            throw AppError.operationFailed("百度搜索触发了安全验证，当前无法无感返回搜索结果。")
        }

        try await Task.sleep(nanoseconds: 400_000_000)
        let raw = try await webView.evaluateJavaScriptString(Self.extractionScript)
        let data = Data(raw.utf8)
        let payload = try JSONDecoder().decode(SearchPayload.self, from: data)

        if payload.title.contains("百度安全验证") {
            throw AppError.operationFailed("百度搜索触发了安全验证，当前无法无感返回搜索结果。")
        }

        let results = payload.results.compactMap { entry -> WebSearchResult? in
            guard let url = URL(string: entry.url), !entry.title.isEmpty else { return nil }
            return WebSearchResult(title: entry.title, url: url, snippet: entry.snippet)
        }

        return results
    }

    private func load(_ request: URLRequest, timeoutSeconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            loadTimeoutTask?.cancel()
            loadTimeoutTask = Task { [weak self] in
                let nanoseconds = UInt64(max(0.5, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                await MainActor.run {
                    self?.finishLoad(
                        .failure(AppError.operationFailed("搜索超时，已返回当前可用结果。"))
                    )
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

    private func finishLoad(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else {
            return
        }
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        loadContinuation = nil
        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            webView.stopLoading()
            continuation.resume(throwing: error)
        }
    }

    private static func isSearchTimeout(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("超时") ||
            error.localizedDescription.localizedCaseInsensitiveContains("timed out")
    }

    private static let extractionScript = #"""
    (() => {
      const normalize = (text) => (text || '').replace(/\s+/g, ' ').trim();
      const trimSnippet = (title, text) => {
        const normalized = normalize(text);
        if (!normalized) return '';
        if (normalized.startsWith(title)) {
          return normalize(normalized.slice(title.length)).slice(0, 220);
        }
        return normalized.slice(0, 220);
      };

      const anchors = Array.from(document.querySelectorAll('h3 a'));
      const seen = new Set();
      const results = [];

      for (const anchor of anchors) {
        const title = normalize(anchor.textContent);
        if (!title) continue;

        const container = anchor.closest('[mu], .result, .result-op, .c-container, .c-result, .xpath-log');
        let url = '';
        if (container && typeof container.getAttribute === 'function') {
          url = container.getAttribute('mu') || '';
        }
        if (!url) {
          url = anchor.href || '';
        }
        if (!url || seen.has(url)) continue;

        const snippet = trimSnippet(title, container?.innerText || anchor.parentElement?.innerText || '');
        seen.add(url);
        results.push({ title, url, snippet });
      }

      return JSON.stringify({
        title: document.title || '',
        results
      });
    })()
    """#
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
