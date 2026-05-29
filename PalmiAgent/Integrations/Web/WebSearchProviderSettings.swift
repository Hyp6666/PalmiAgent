import Foundation

enum WebSearchProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
    case baidu
    case bing
    case duckDuckGo
    case sogou
    case so360

    var id: String { rawValue }

    var title: String {
        switch self {
        case .baidu:
            "百度"
        case .bing:
            "必应"
        case .duckDuckGo:
            "DuckDuckGo"
        case .sogou:
            "搜狗"
        case .so360:
            "360 搜索"
        }
    }

    var technicalTitle: String {
        switch self {
        case .baidu:
            "Baidu via WebKit"
        case .bing:
            "Bing HTML"
        case .duckDuckGo:
            "DuckDuckGo HTML"
        case .sogou:
            "Sogou HTML"
        case .so360:
            "360 Search HTML"
        }
    }

    var regionNote: String {
        switch self {
        case .baidu, .sogou, .so360:
            "国内网络优先"
        case .bing, .duckDuckGo:
            "可能依赖国际网络"
        }
    }

    var searchURLHost: String {
        switch self {
        case .baidu:
            "www.baidu.com"
        case .bing:
            "www.bing.com"
        case .duckDuckGo:
            "duckduckgo.com"
        case .sogou:
            "www.sogou.com"
        case .so360:
            "www.so.com"
        }
    }

    nonisolated var probeURL: URL {
        switch self {
        case .baidu:
            URL(string: "https://www.baidu.com/")!
        case .bing:
            URL(string: "https://www.bing.com/")!
        case .duckDuckGo:
            URL(string: "https://duckduckgo.com/html/")!
        case .sogou:
            URL(string: "https://www.sogou.com/")!
        case .so360:
            URL(string: "https://www.so.com/")!
        }
    }

    func searchURL(query: String) throws -> URL {
        var components: URLComponents
        switch self {
        case .baidu:
            components = URLComponents(string: "https://www.baidu.com/s")!
            components.queryItems = [
                URLQueryItem(name: "wd", value: query),
                URLQueryItem(name: "ie", value: "utf-8")
            ]
        case .bing:
            components = URLComponents(string: "https://www.bing.com/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query)
            ]
        case .duckDuckGo:
            components = URLComponents(string: "https://duckduckgo.com/html/")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query)
            ]
        case .sogou:
            components = URLComponents(string: "https://www.sogou.com/web")!
            components.queryItems = [
                URLQueryItem(name: "query", value: query)
            ]
        case .so360:
            components = URLComponents(string: "https://www.so.com/s")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query)
            ]
        }

        guard let url = components.url else {
            throw AppError.invalidState("搜索源 URL 生成失败：\(title)")
        }
        return url
    }
}

enum WebSearchProviderSettings {
    static let disabledProviderIDsStorageKey = "palmi.web-search.disabled-provider-ids.v1"

    static var defaultProviderID: WebSearchProviderID {
        .baidu
    }

    static func enabledProviderIDs(userDefaults: UserDefaults = .standard) -> [WebSearchProviderID] {
        let disabled = disabledProviderIDs(userDefaults: userDefaults)
        let enabled = WebSearchProviderID.allCases.filter { !disabled.contains($0) }
        return enabled.isEmpty ? [defaultProviderID] : enabled
    }

    static func isEnabled(_ providerID: WebSearchProviderID, userDefaults: UserDefaults = .standard) -> Bool {
        enabledProviderIDs(userDefaults: userDefaults).contains(providerID)
    }

    static func setEnabled(
        _ enabled: Bool,
        providerID: WebSearchProviderID,
        userDefaults: UserDefaults = .standard
    ) {
        var disabled = disabledProviderIDs(userDefaults: userDefaults)
        if enabled {
            disabled.remove(providerID)
        } else {
            let currentlyEnabled = WebSearchProviderID.allCases.filter { !disabled.contains($0) }
            guard currentlyEnabled.count > 1 else {
                return
            }
            disabled.insert(providerID)
        }
        userDefaults.set(disabled.map(\.rawValue).sorted(), forKey: disabledProviderIDsStorageKey)
    }

    static func provider(id rawValue: String) -> WebSearchProviderID? {
        WebSearchProviderID(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func enabledProviderIDsDescription(userDefaults: UserDefaults = .standard) -> String {
        enabledProviderIDs(userDefaults: userDefaults)
            .map { "\($0.rawValue)=\($0.title)" }
            .joined(separator: "、")
    }

    private static func disabledProviderIDs(userDefaults: UserDefaults) -> Set<WebSearchProviderID> {
        let rawValues = userDefaults.stringArray(forKey: disabledProviderIDsStorageKey) ?? []
        return Set(rawValues.compactMap(WebSearchProviderID.init(rawValue:)))
    }
}
