import Foundation

/// Safari's common providers plus regional choices. Independent of Palmi's agent search tools.
enum BrowserSearchEngine: String, CaseIterable, Identifiable, Sendable {
    case google, yahoo, bing, duckDuckGo, ecosia, baidu, sogou, so360, yandex
    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .yahoo: "Yahoo"
        case .bing: "Bing"
        case .duckDuckGo: "DuckDuckGo"
        case .ecosia: "Ecosia"
        case .baidu: "百度"
        case .sogou: "搜狗"
        case .so360: "360 搜索"
        case .yandex: "Yandex"
        }
    }

    func searchURL(for query: String) -> URL? {
        let endpoint: String
        let parameter: String
        switch self {
        case .google: (endpoint, parameter) = ("https://www.google.com/search", "q")
        case .yahoo: (endpoint, parameter) = ("https://search.yahoo.com/search", "p")
        case .bing: (endpoint, parameter) = ("https://www.bing.com/search", "q")
        case .duckDuckGo: (endpoint, parameter) = ("https://duckduckgo.com/", "q")
        case .ecosia: (endpoint, parameter) = ("https://www.ecosia.org/search", "q")
        case .baidu: (endpoint, parameter) = ("https://www.baidu.com/s", "wd")
        case .sogou: (endpoint, parameter) = ("https://www.sogou.com/web", "query")
        case .so360: (endpoint, parameter) = ("https://www.so.com/s", "q")
        case .yandex: (endpoint, parameter) = ("https://yandex.com/search/", "text")
        }
        var components = URLComponents(string: endpoint)
        components?.queryItems = [URLQueryItem(name: parameter, value: query)]
        return components?.url
    }

    func destination(for input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let hasWhitespace = value.contains(where: \.isWhitespace)
        let candidate = value.contains("://") ? URL(string: value)
            : (!hasWhitespace && (value.contains(".") || value == "localhost" || value.hasPrefix("localhost:"))
               ? URL(string: "https://" + value) : nil)
        if let candidate, BrowserSafety.allowsNavigation(candidate) { return candidate }
        return searchURL(for: value)
    }
}
