import Foundation
import CoreFoundation

enum BrowserOperation: String, CaseIterable, Sendable {
    case open, observe, click, type, select, press, scroll, back, forward, reload, look, handoff, tabs, close

    var isRead: Bool {
        switch self {
        // 滚动只改变视口；接管只是把页面交给用户，本身不改变网站状态。二者归入读取类，免审批、可重试。
        case .open, .observe, .look, .close, .back, .forward, .reload, .scroll, .handoff, .tabs: true
        default: false
        }
    }

    var actionID: ToolActionID { .browser }
}

struct BrowserToolError: LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { "error: \(code)\nmessage: \(message)" }

    static let foreground = BrowserToolError(code: "requires_foreground", message: "Palmi 进入后台，进行中的网页操作被中断，结果未知。请先 observe 确认页面状态。")
    static let stale = BrowserToolError(code: "stale_observation", message: "元素编号已过期，请先 observe，使用最新 observation_id 和 e 编号。")
    static let sensitive = BrowserToolError(code: "sensitive_field", message: "禁止自动输入密码或支付字段，请使用 handoff 交给用户操作。")
}

struct BrowserRequest: Sendable {
    let operation: BrowserOperation
    let url: URL?
    let scope: String
    let start: Int
    let count: Int
    let ref: String?
    let observationID: String?
    let x: Double?
    let y: Double?
    let text: String?
    let clear: Bool
    let submit: Bool
    let value: String?
    let key: String?
    let direction: String?
    let amount: Double
    let question: String?
    let reason: String?
    /// 目标标签页（如 t3）；省略时使用本对话当前的标签页。
    let tab: String?
    /// open 时是否新建标签页。
    let newTab: Bool

    init(arguments a: ToolArguments) throws {
        func invalid(_ message: String) -> BrowserToolError { .init(code: "invalid_arguments", message: message) }
        func string(_ name: String, required: Bool = false, allowEmpty: Bool = false) throws -> String? {
            guard a.contains(name) else {
                if required { throw invalid("缺少必填参数：\(name)") }
                return nil
            }
            guard let value = a.string(name), allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("\(name) 必须是\(allowEmpty ? "" : "非空")字符串。")
            }
            guard value.count <= 20_000 else { throw invalid("\(name) 超过 20000 字符上限。") }
            return value
        }
        func number(_ name: String, fallback: Double? = nil) throws -> Double? {
            guard a.contains(name) else { return fallback }
            guard let n = a.anyValue(name) as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                throw invalid("\(name) 必须是有限数字。")
            }
            return n.doubleValue
        }
        func boolean(_ name: String, fallback: Bool) throws -> Bool {
            guard a.contains(name) else { return fallback }
            guard let n = a.anyValue(name) as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                throw invalid("\(name) 必须是布尔值。")
            }
            return n.boolValue
        }
        guard let name = try string("operation", required: true), let op = BrowserOperation(rawValue: name) else {
            throw invalid("browser.operation 不受支持。")
        }
        operation = op
        var fields: [String]
        switch op {
        case .open: fields = ["url", "new_tab"]
        case .observe: fields = ["scope", "start", "count"]
        case .click: fields = ["ref", "observation_id", "x", "y"]
        case .type: fields = ["ref", "observation_id", "text", "clear", "submit"]
        case .select: fields = ["ref", "observation_id", "value"]
        case .press: fields = ["key"]
        case .scroll: fields = ["ref", "observation_id", "direction", "amount"]
        case .look: fields = ["question"]
        case .handoff: fields = ["reason"]
        default: fields = []
        }
        if op != .tabs { fields.append("tab") }
        let object = try JSONSerialization.jsonObject(with: Data(a.normalizedJSONString().utf8)) as? [String: Any] ?? [:]
        guard Set(object.keys).isSubset(of: Set(fields + ["operation"])) else { throw invalid("含有本操作不支持的参数。") }
        if op == .open {
            let raw = try string("url", required: true)!
            guard let target = URL(string: raw), BrowserSafety.allowsNavigation(target) else {
                throw BrowserToolError(code: "blocked_navigation", message: "仅支持有效的 http/https 网页地址。")
            }
            url = target
        } else { url = nil }
        scope = try string("scope") ?? "interactive"
        guard ["interactive", "text"].contains(scope) else { throw invalid("scope 只支持 interactive 或 text。") }
        let offset = try number("start", fallback: 0)!
        let limit = try number("count", fallback: 1000)!
        guard offset >= 0, offset <= Double(Int.max / 2), offset.rounded() == offset,
              limit >= 1, limit <= 20_000, limit.rounded() == limit else { throw invalid("start 必须为非负整数，count 必须为 1–20000 的整数。") }
        start = Int(offset)
        count = Int(limit)
        if scope != "text", a.contains("start") || a.contains("count") { throw invalid("start/count 只用于 scope=text。") }
        ref = try string("ref")
        observationID = try string("observation_id")
        if let ref, ref.range(of: "^e[1-9][0-9]{0,5}$", options: .regularExpression) == nil { throw invalid("ref 必须是观察中的 e 编号。") }
        if (ref == nil) != (observationID == nil) { throw invalid("ref 与 observation_id 必须同时提供。") }
        x = try number("x")
        y = try number("y")
        if (x == nil) != (y == nil) || (x != nil && ref != nil) { throw invalid("ref 与 x/y 二选一，坐标必须同时提供。") }
        if let x, let y, x < 0 || y < 0 { throw invalid("视口坐标不能为负数。") }
        if op == .click, ref == nil && x == nil { throw invalid("click 需要 ref 或 x/y。") }
        if op == .type || op == .select, ref == nil { throw invalid("本操作需要 ref 和 observation_id。") }
        text = try string("text", required: op == .type, allowEmpty: true)
        clear = try boolean("clear", fallback: true)
        submit = try boolean("submit", fallback: false)
        value = try string("value", required: op == .select, allowEmpty: true)
        key = try string("key", required: op == .press)
        if let key, !["Enter", "Tab", "Escape"].contains(key) { throw invalid("key 只支持 Enter、Tab、Escape。") }
        direction = try string("direction")
        amount = try number("amount", fallback: 0.8)!
        guard (0.25...3).contains(amount) else { throw invalid("amount 必须在 0.25–3 屏之间。") }
        if op == .scroll {
            if ref != nil {
                guard direction == nil, !a.contains("amount") else { throw invalid("元素滚动与 direction/amount 二选一。") }
            } else {
                guard let direction, ["up", "down"].contains(direction) else { throw invalid("scroll 需要 up/down 或元素编号。") }
            }
        }
        question = try string("question", required: op == .look)
        reason = try string("reason", required: op == .handoff)
        tab = try string("tab")
        if let tab, tab.range(of: "^t[1-9][0-9]{0,5}$", options: .regularExpression) == nil { throw invalid("tab 必须是 tabs 返回的 t 编号。") }
        newTab = try boolean("new_tab", fallback: false)
        if newTab, tab != nil { throw invalid("new_tab 与 tab 二选一。") }
    }
}

enum BrowserSafety {
    static func allowsNavigation(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    static func allowsResponse(isDownload: Bool, canShowMIMEType: Bool) -> Bool {
        !isDownload && canShowMIMEType
    }

    static func isSensitiveField(type: String, autocomplete: String) -> Bool {
        type.lowercased() == "password" || autocomplete.lowercased().split(whereSeparator: { $0.isWhitespace }).contains { $0.hasPrefix("cc-") }
    }
}

struct BrowserObservationLedger: Sendable {
    private let nonce = UUID().uuidString.prefix(8)
    private var sequence = 0
    private(set) var latest: String?

    mutating func issue() -> String {
        sequence += 1
        let id = "o\(sequence)-\(nonce)"
        latest = id
        return id
    }

    mutating func invalidate() { latest = nil }
    func validate(_ id: String) throws {
        guard latest == id else { throw BrowserToolError.stale }
    }
}

struct BrowserElement: Decodable, Sendable {
    let ref: String
    let role: String
    let label: String
    let value: String?
    let href: String?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum BrowserOutputLimits {
    // 现有工具上下文会压缩超出 1600 字符的 details；在工具内完整分段，保留编号和分页边界。
    static let maxCharacters = 1600
    static func notices(_ text: String) -> String { String(text.prefix(240)) }
}

struct BrowserObservation: Decodable, Sendable {
    let id: String
    let url: String
    let title: String
    let width: Double
    let height: Double
    let scrollY: Double
    let scrollHeight: Double
    let elements: [BrowserElement]
    let offscreenCount: Int
    let crossOriginFrameCount: Int
    let text: String

    var header: String {
        "observation_id: \(id)\nurl: \(Self.line(url, limit: 240))   title: \(Self.line(title, limit: 80))\nviewport: \(Int(width))x\(Int(height))  scroll: \(Int(scrollY))/\(Int(scrollHeight))"
    }

    func formatted(maxCharacters: Int = BrowserOutputLimits.maxCharacters) -> String {
        var lines = [header]
        let elementLines = elements.prefix(60).map { e in
            var line = "[\(e.ref)] \(e.role) \"\(Self.line(e.label, limit: 80))\""
            if let value = e.value { line += " value=\"\(Self.line(value, limit: 80))\"" }
            if let href = e.href { line += " -> \(Self.line(href, limit: 96))" }
            return line
        }
        var notes: [String] = []
        if offscreenCount > 0 { notes.append("（视口外另有 \(offscreenCount) 个可交互元素）") }
        if crossOriginFrameCount > 0 { notes.append("（有 \(crossOriginFrameCount) 个跨域 iframe 无法读取；请用 look 理解画面，必要时使用视口坐标）") }
        let reserved = notes.joined(separator: "\n").count + 100 + min(180, text.count)
        var used = header.count
        var shown = 0
        for line in elementLines {
            guard used + line.count + 1 + reserved <= maxCharacters else { break }
            lines.append(line)
            used += line.count + 1
            shown += 1
        }
        if elements.count > shown { notes.append("（视口内另有 \(elements.count - shown) 个元素未列出；可滚动或 look 定位）") }
        lines += notes
        let remaining = max(0, maxCharacters - lines.joined(separator: "\n").count - 8)
        let excerpt = String(text.prefix(min(1500, remaining)))
        lines.append("text: \(excerpt)\(text.count > excerpt.count ? "…" : "")")
        return String(lines.joined(separator: "\n").prefix(max(0, maxCharacters)))
    }

    static func line(_ text: String, limit: Int) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\"", with: "’")
        return normalized.count <= limit ? normalized : String(normalized.prefix(max(0, limit - 1))) + "…"
    }
}

struct BrowserTextPage: Sendable {
    let text: String
    let start: Int
    let nextStart: Int
    let total: Int

    init(text: String, start: Int, count: Int) {
        total = text.count
        self.start = min(max(0, start), total)
        self.text = String(text.dropFirst(self.start).prefix(min(max(count, 1), 20_000)))
        nextStart = self.start + self.text.count
    }

    func formatted() -> String { "text_start: \(start)  next_start: \(nextStart)  total: \(total)\ntext: \(text)" }
}
