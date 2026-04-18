import Foundation
import UIKit

@MainActor
final class SystemRouter {
    func openAppSettings() throws {
        try open(urlString: UIApplication.openSettingsURLString, fallbackMessage: "无法打开当前应用的设置页。")
    }

    func openMailDraft(
        directURL: String? = nil,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String?,
        body: String?
    ) throws {
        if let directURL, !directURL.isEmpty {
            try open(urlString: directURL, fallbackMessage: "系统没有可用的邮件处理器。")
            return
        }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.joined(separator: ",")

        var queryItems: [URLQueryItem] = []
        if !cc.isEmpty { queryItems.append(URLQueryItem(name: "cc", value: cc.joined(separator: ","))) }
        if !bcc.isEmpty { queryItems.append(URLQueryItem(name: "bcc", value: bcc.joined(separator: ","))) }
        if let subject, !subject.isEmpty { queryItems.append(URLQueryItem(name: "subject", value: subject)) }
        if let body, !body.isEmpty { queryItems.append(URLQueryItem(name: "body", value: body)) }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let urlString = components.url?.absoluteString else {
            throw AppError.invalidState("邮件草稿 URL 生成失败。")
        }
        try open(urlString: urlString, fallbackMessage: "系统没有可用的邮件处理器。")
    }

    func openMessageDraft(directURL: String? = nil, recipients: [String], body: String?) throws {
        if let directURL, !directURL.isEmpty {
            try open(urlString: directURL, fallbackMessage: "系统没有可用的短信处理器。")
            return
        }

        var components = URLComponents()
        components.scheme = "sms"
        components.path = recipients.joined(separator: ",")
        if let body, !body.isEmpty {
            components.queryItems = [URLQueryItem(name: "body", value: body)]
        }

        guard let urlString = components.url?.absoluteString else {
            throw AppError.invalidState("短信草稿 URL 生成失败。")
        }
        try open(urlString: urlString, fallbackMessage: "系统没有可用的短信处理器。")
    }

    func call(number: String) throws {
        try open(urlString: "tel://\(number)", fallbackMessage: "当前设备无法发起电话。")
    }

    func openFaceTime(target: String, callType: String? = nil) throws {
        if target.lowercased().hasPrefix("facetime://") || target.lowercased().hasPrefix("https://") {
            try open(urlString: target, fallbackMessage: "当前设备无法打开 FaceTime。")
            return
        }
        let scheme = switch callType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "audio":
            "facetime-audio://"
        default:
            "facetime://"
        }
        try open(urlString: "\(scheme)\(target)", fallbackMessage: "当前设备无法打开 FaceTime。")
    }

    func openAppStore(
        searchTerm: String?,
        appID: String?,
        directURL: String? = nil,
        countryCode: String? = nil
    ) throws {
        if let directURL, !directURL.isEmpty {
            try open(urlString: directURL, fallbackMessage: "无法打开 App Store。")
            return
        }

        let countryCode = normalizedCountryCode(countryCode)
        if let appID, !appID.isEmpty {
            try open(urlString: "https://apps.apple.com/\(countryCode)/app/id\(appID)", fallbackMessage: "无法打开 App Store。")
            return
        }
        let term = (searchTerm?.isEmpty == false ? searchTerm : "效率工具") ?? "效率工具"
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        try open(urlString: "https://apps.apple.com/\(countryCode)/search?term=\(encoded)", fallbackMessage: "无法打开 App Store。")
    }

    func openPodcasts(url: String?, searchTerm: String?, countryCode: String? = nil) throws {
        let countryCode = normalizedCountryCode(countryCode)
        try openContentApp(
            directURL: url,
            searchTerm: searchTerm,
            baseURL: "https://podcasts.apple.com/\(countryCode)",
            searchPrefix: "https://podcasts.apple.com/\(countryCode)/search?term=",
            fallbackMessage: "无法打开播客。"
        )
    }

    func openBooks(url: String?, searchTerm: String?, countryCode: String? = nil) throws {
        let countryCode = normalizedCountryCode(countryCode)
        try openContentApp(
            directURL: url,
            searchTerm: searchTerm,
            baseURL: "https://books.apple.com/\(countryCode)",
            searchPrefix: "https://books.apple.com/\(countryCode)/search?term=",
            fallbackMessage: "无法打开图书。"
        )
    }

    func openTV(url: String?, searchTerm: String?, countryCode: String? = nil) throws {
        let countryCode = normalizedCountryCode(countryCode)
        try openContentApp(
            directURL: url,
            searchTerm: searchTerm,
            baseURL: "https://tv.apple.com/\(countryCode)",
            searchPrefix: "https://tv.apple.com/search?term=",
            fallbackMessage: "无法打开视频。"
        )
    }

    private func openContentApp(
        directURL: String?,
        searchTerm: String?,
        baseURL: String,
        searchPrefix: String,
        fallbackMessage: String
    ) throws {
        if let directURL, !directURL.isEmpty {
            try open(urlString: directURL, fallbackMessage: fallbackMessage)
            return
        }
        if let searchTerm, !searchTerm.isEmpty {
            let encoded = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? searchTerm
            try open(urlString: searchPrefix + encoded, fallbackMessage: fallbackMessage)
            return
        }
        try open(urlString: baseURL, fallbackMessage: fallbackMessage)
    }

    private func open(urlString: String, fallbackMessage: String) throws {
        guard let url = URL(string: urlString) else {
            throw AppError.invalidState("URL 生成失败：\(urlString)")
        }
        guard UIApplication.shared.canOpenURL(url) else {
            throw AppError.unsupported(fallbackMessage)
        }
        UIApplication.shared.open(url)
    }

    private func normalizedCountryCode(_ countryCode: String?) -> String {
        let normalized = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized.isEmpty ? "cn" : normalized
    }
}
