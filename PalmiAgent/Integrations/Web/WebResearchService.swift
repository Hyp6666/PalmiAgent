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

final class WebResearchService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    @MainActor
    func search(query: String, maxResults: Int = 30) async throws -> [WebSearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw AppError.invalidState("搜索关键词不能为空。")
        }
        let driver = BaiduSearchWebViewDriver()
        return try await driver.search(query: trimmedQuery, maxResults: maxResults)
    }

    func fetchSummary(from url: URL, maxBodyCharacters: Int = 500) async throws -> WebFetchSummary {
        let (html, byteCount) = try await loadHTML(from: url)
        let title = Self.extractTitle(from: html) ?? url.host ?? "网页"
        let plainText = Self.extractBodyText(from: html, maxBodyCharacters: maxBodyCharacters)
        return WebFetchSummary(title: title, url: url, bodyText: plainText, byteCount: byteCount)
    }

    func batchFetch(urls: [URL], maxBodyCharacters: Int = 500) async throws -> [WebFetchSummary] {
        let attempts = await fetchAttempts(urls: urls, maxBodyCharacters: maxBodyCharacters)
        if let failedAttempt = attempts.first(where: { $0.summary == nil }) {
            throw AppError.operationFailed(failedAttempt.errorDescription ?? "网页抓取失败。")
        }
        return attempts.compactMap(\.summary)
    }

    func batchFetchBestEffort(urls: [URL], maxBodyCharacters: Int = 500) async -> [WebFetchAttempt] {
        await fetchAttempts(urls: urls, maxBodyCharacters: maxBodyCharacters)
    }

    private func loadHTML(from url: URL) async throws -> (html: String, byteCount: Int) {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh-Hans;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await session.data(for: request)
        return (String(decoding: data, as: UTF8.self), data.count)
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

    private func fetchAttempts(urls: [URL], maxBodyCharacters: Int) async -> [WebFetchAttempt] {
        await withTaskGroup(of: (Int, WebFetchAttempt).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let summary = try await self.fetchSummary(from: url, maxBodyCharacters: maxBodyCharacters)
                        return (
                            index,
                            WebFetchAttempt(
                                url: url,
                                summary: summary,
                                errorDescription: nil
                            )
                        )
                    } catch {
                        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        return (
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

            var indexedAttempts: [(Int, WebFetchAttempt)] = []
            for await result in group {
                indexedAttempts.append(result)
            }

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

    func search(query: String, maxResults: Int) async throws -> [WebSearchResult] {
        let requestedResults = min(max(1, maxResults), Self.maxSearchResults)
        let pageCount = max(1, Int(ceil(Double(requestedResults) / Double(Self.pageSize))))
        var collected: [WebSearchResult] = []
        var seenURLs: Set<String> = []

        for pageIndex in 0..<pageCount {
            do {
                let pageResults = try await searchPage(query: query, offset: pageIndex * Self.pageSize)
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
                if collected.isEmpty {
                    throw error
                }
                break
            }
        }

        return Array(collected.prefix(requestedResults))
    }

    private func searchPage(query: String, offset: Int) async throws -> [WebSearchResult] {
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
        request.setValue("zh-CN,zh;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")

        try await load(request)

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

    private func load(_ request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.load(request)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
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
