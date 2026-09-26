import Foundation
import Observation
import Security

nonisolated struct ChatGPTAccountReference: Codable, Equatable, Sendable {
    let accountID: String
    let email: String
}
nonisolated struct ChatGPTCatalogModel: Identifiable, Sendable {
    let id: String
    let title: String
    let vision: Bool
    let imageOnly: Bool
}
nonisolated struct ChatGPTDeviceChallenge: Equatable, Sendable {
    let code: String
    let expiresAt: Date
}
nonisolated struct ChatGPTConnectionError: LocalizedError {
    let code: String
    let status: Int?
    private let message: String
    @MainActor init(_ code: String, status: Int? = nil) {
        self.code = code; self.status = status
        let text = PalmiL10n.tr("chatgpt.error." + code)
        message = status.map { text + " (HTTP \($0))" } ?? text
    }
    var errorDescription: String? { message }
}
nonisolated private final class ChatGPTNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor @Observable
final class ChatGPTAccountStore {
    static let shared = ChatGPTAccountStore()
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let compatibility = "0.157.1"
    static let base = URL(string: "https://chatgpt.com/backend-api/codex")!
    static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
    static let imageModelIDs = ["gpt-image-2.5-flare", "gpt-image-2.5-sunburst", "gpt-image-2", "gpt-image-1.5"]
    nonisolated private struct Credentials: Codable, Sendable {
        let account: ChatGPTAccountReference
        let access: String
        let refresh: String
        let expiresAt: Date
    }
    private(set) var account: ChatGPTAccountReference?
    private(set) var challenge: ChatGPTDeviceChallenge?
    private(set) var signingIn = false
    private(set) var revision = 0
    var errorMessage: String?
    @ObservationIgnored private var credentials: Credentials?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var refreshTask: Task<Credentials, Error>?
    @ObservationIgnored private var refreshTaskID: UUID?
    @ObservationIgnored private let redirect = ChatGPTNoRedirect()
    @ObservationIgnored private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.httpCookieStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 600
        return URLSession(configuration: c, delegate: redirect, delegateQueue: nil)
    }()
    var responseSession: URLSession { session }

    private init() {
        do {
            if let data = try readCredentialData() {
                let value = try JSONDecoder().decode(Credentials.self, from: data)
                credentials = value; account = value.account
            }
        } catch { errorMessage = PalmiL10n.tr("chatgpt.error.credentials") }
    }
    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "PalmiAgent.ChatGPTOAuth",
         kSecAttrAccount as String: "active-account"]
    }
    private func readCredentialData() throws -> Data? {
        var q = keychainQuery
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ChatGPTConnectionError("credentials") }
        return data
    }
    private func save(_ value: Credentials) throws {
        let data = try JSONEncoder().encode(value)
        let attrs: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(keychainQuery as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(keychainQuery.merging(attrs, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ChatGPTConnectionError("credentials") }
        credentials = value; account = value.account; revision &+= 1
    }
    func cancelSignIn() { epoch = UUID(); signingIn = false; challenge = nil }
    func signOut() throws {
        let status = SecItemDelete(keychainQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatGPTConnectionError("credentials") }
        cancelSignIn(); refreshTask?.cancel(); refreshTask = nil; refreshTaskID = nil
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        credentials = nil; account = nil; revision &+= 1
    }
    func signIn() async {
        guard !signingIn else { return }
        epoch = UUID(); let ticket = epoch
        signingIn = true; errorMessage = nil
        defer { if ticket == epoch { signingIn = false; challenge = nil } }
        do {
            let start = try await jsonRequest("https://auth.openai.com/api/accounts/deviceauth/usercode",
                                             body: ["client_id": Self.clientID])
            guard let device = start["device_auth_id"] as? String,
                  let code = start["user_code"] as? String, !device.isEmpty, !code.isEmpty else {
                throw ChatGPTConnectionError("device")
            }
            let rawInterval = (start["interval"] as? NSNumber)?.doubleValue
                ?? Double(start["interval"] as? String ?? "") ?? 5
            let interval = min(60, max(5, rawInterval))
            let expiry = Date.now.addingTimeInterval(900)
            guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
            challenge = .init(code: code, expiresAt: expiry)
            while Date.now < expiry {
                try await Task.sleep(for: .seconds(interval))
                guard ticket == epoch else { throw CancellationError() }
                var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["device_auth_id": device, "user_code": code])
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ChatGPTConnectionError("device") }
                if [403, 404].contains(http.statusCode) { continue }
                guard http.statusCode == 200, data.count <= 1_048_576,
                      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let authCode = result["authorization_code"] as? String,
                      let verifier = result["code_verifier"] as? String else {
                    throw ChatGPTConnectionError("device", status: http.statusCode)
                }
                let tokens = try await tokenRequest(["grant_type": "authorization_code", "code": authCode,
                    "code_verifier": verifier, "client_id": Self.clientID,
                    "redirect_uri": "https://auth.openai.com/deviceauth/callback"])
                let value = try makeCredentials(tokens, previous: nil)
                guard ticket == epoch, !Task.isCancelled else { throw CancellationError() }
                try save(value)
                return
            }
            throw ChatGPTConnectionError("expired")
        } catch is CancellationError { }
        catch { if ticket == epoch { errorMessage = error.localizedDescription } }
    }
    func accessToken(accountID: String, forceRefresh: Bool = false) async throws -> String {
        guard let old = credentials, old.account.accountID == accountID else { throw ChatGPTConnectionError("signIn") }
        if !forceRefresh, old.expiresAt.timeIntervalSinceNow > 90 { return old.access }
        if let refreshTask { return try await refreshTask.value.access }
        let ticket = epoch, taskID = UUID()
        let task = Task { @MainActor () throws -> Credentials in
            let payload = try await self.tokenRequest(["grant_type": "refresh_token", "refresh_token": old.refresh,
                                                       "client_id": Self.clientID])
            let fresh = try self.makeCredentials(payload, previous: old)
            guard ticket == self.epoch, self.credentials?.account.accountID == accountID,
                  fresh.account.accountID == accountID, !Task.isCancelled else { throw CancellationError() }
            try self.save(fresh)
            return fresh
        }
        refreshTask = task; refreshTaskID = taskID
        defer { if refreshTaskID == taskID { refreshTask = nil; refreshTaskID = nil } }
        return try await task.value.access
    }
    func authorizedRequest(path: String, accountID: String, body: Data? = nil) async throws -> URLRequest {
        guard ["responses", "models", "images/generations"].contains(path) else { throw ChatGPTConnectionError("request") }
        let token = try await accessToken(accountID: accountID)
        var url = Self.base.appendingPathComponent(path)
        if path == "models" {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "client_version", value: Self.compatibility)]
            url = parts.url!
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("PalmiAgent", forHTTPHeaderField: "originator")
        request.setValue(Self.compatibility, forHTTPHeaderField: "version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    func prepareResponses(_ raw: URLRequest, accountID: String) async throws -> URLRequest {
        guard let data = raw.httpBody,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTConnectionError("request")
        }
        object["stream"] = true; object["store"] = false
        for key in ["max_output_tokens", "max_completion_tokens", "temperature", "top_p", "truncation"] {
            object.removeValue(forKey: key)
        }
        var instructions = (object["instructions"] as? String).map { [$0] } ?? []
        if let input = object["input"] as? [[String: Any]] {
            object["input"] = input.filter { row in
                guard let role = row["role"] as? String, ["system", "developer"].contains(role) else { return true }
                if let text = row["content"] as? String { instructions.append(text) }
                else if let parts = row["content"] as? [[String: Any]] {
                    instructions.append(contentsOf: parts.compactMap { $0["text"] as? String })
                }
                return false
            }
        }
        object["instructions"] = instructions.joined(separator: "\n\n")
        var request = try await authorizedRequest(path: "responses", accountID: accountID,
                                                 body: JSONSerialization.data(withJSONObject: object))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return request
    }
    func refreshCatalog() async throws -> [ChatGPTCatalogModel] {
        guard let account else { throw ChatGPTConnectionError("signIn") }
        var request = try await authorizedRequest(path: "models", accountID: account.accountID)
        var result = try await session.data(for: request)
        if (result.1 as? HTTPURLResponse)?.statusCode == 401 {
            _ = try await accessToken(accountID: account.accountID, forceRefresh: true)
            request = try await authorizedRequest(path: "models", accountID: account.accountID)
            result = try await session.data(for: request)
        }
        guard self.account?.accountID == account.accountID,
              let http = result.1 as? HTTPURLResponse, http.statusCode == 200,
              result.0.count <= 4 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let rows = object["models"] as? [[String: Any]] else { throw ChatGPTConnectionError("catalog") }
        var seen = Set<String>(), output: [ChatGPTCatalogModel] = []
        for row in rows {
            guard let id = row["slug"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
            let modalities = row["input_modalities"] as? [String] ?? []
            output.append(.init(id: id, title: row["display_name"] as? String ?? id,
                vision: modalities.contains("image"), imageOnly: Self.imageModelIDs.contains(id)))
        }
        guard !output.isEmpty else { throw ChatGPTConnectionError("catalog") }
        for id in Self.imageModelIDs where seen.insert(id).inserted {
            output.append(.init(id: id, title: id, vision: false, imageOnly: true))
        }
        return output
    }
    func imageResponse(_ request: URLRequest, accountID: String) async throws -> Data {
        guard account?.accountID == accountID, request.url?.host == "chatgpt.com",
              request.url?.path == "/backend-api/codex/images/generations" else { throw ChatGPTConnectionError("request") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChatGPTConnectionError("image", status: (response as? HTTPURLResponse)?.statusCode)
        }
        guard account?.accountID == accountID, data.count <= 64 * 1024 * 1024 else {
            throw ChatGPTConnectionError("responseSize")
        }
        return data
    }
    private func jsonRequest(_ address: String, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1_048_576,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTConnectionError("device") }
        return result
    }
    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
                + fields[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1_048_576,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTConnectionError("credentials", status: (response as? HTTPURLResponse)?.statusCode)
        }
        return result
    }
    private func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text), data.count <= 65_536,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private func makeCredentials(_ value: [String: Any], previous: Credentials?) throws -> Credentials {
        guard let access = value["access_token"] as? String, !access.isEmpty,
              let refresh = value["refresh_token"] as? String ?? previous?.refresh, !refresh.isEmpty else {
            throw ChatGPTConnectionError("credentials")
        }
        let id = claims(value["id_token"] as? String ?? ""), token = claims(access)
        let auth = id["https://api.openai.com/auth"] as? [String: Any]
            ?? token["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        guard let accountID = auth["chatgpt_account_id"] as? String ?? previous?.account.accountID,
              !accountID.isEmpty else { throw ChatGPTConnectionError("credentials") }
        let profile = token["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        let email = id["email"] as? String ?? profile["email"] as? String ?? previous?.account.email ?? ""
        let seconds = (value["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let date = (token["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            ?? Date.now.addingTimeInterval(max(60, seconds))
        return Credentials(account: .init(accountID: accountID, email: email), access: access,
                           refresh: refresh, expiresAt: date)
    }
}
