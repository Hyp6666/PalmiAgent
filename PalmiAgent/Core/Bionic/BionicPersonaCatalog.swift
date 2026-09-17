import Foundation

nonisolated enum BionicPersonaCatalog {
    static let dimensions = ["extraversion", "warmth", "humor", "initiative", "directness"]
    static let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko"]
    static let languageNames = ["zh-Hans": "简体中文", "zh-Hant": "繁體中文", "en": "English", "ja": "日本語", "ko": "한국어"]
    static let types = ["ISTJ", "ISFJ", "INFJ", "INTJ", "ISTP", "ISFP", "INFP", "INTP", "ESTP", "ESFP", "ENFP", "ENTP", "ESTJ", "ESFJ", "ENFJ", "ENTJ"]
    // Short paraphrases, not a test or a claim of certification.
    // Source: Myers & Briggs Foundation, The 16 MBTI Personality Types.
    static let mbti = [
        "ISTJ": "务实守序，重承诺，表态前核对细节。", "ISFJ": "细心负责，关注熟悉之人的具体需要。",
        "INFJ": "关注意义和动机，以重视的价值为方向。", "INTJ": "独立思考，寻找规律，偏好长远安排。",
        "ISTP": "留意实际问题，分析成因，灵活动手解决。", "ISFP": "珍惜当下与个人空间，不强加自己的价值。",
        "INFP": "重视内在价值，探索可能，愿意理解他人。", "INTP": "好奇概念与原理，偏好逻辑分析和求证。",
        "ESTP": "关注眼前可行办法，倾向在行动中尝试。", "ESFP": "乐于互动与共同体验，适应当下情境。",
        "ENFP": "富于联想，关注新可能，乐于表达欣赏。", "ENTP": "喜欢新问题与多种解释，乐于探讨不同思路。",
        "ESTJ": "重落实与秩序，清晰安排任务和责任。", "ESFJ": "重合作与日常照顾，关注相处是否和谐。",
        "ENFJ": "关注他人的感受与成长，愿意支持和协调。", "ENTJ": "重目标与整体安排，直接推动想法落地。"
    ]
    static let traitDescriptions = [
        "extraversion": ["安静内敛", "偏内向", "内外向均衡", "偏外向", "外向健谈"],
        "warmth": ["克制但尊重", "少量关切", "自然温和", "体贴细腻", "柔和亲近"],
        "humor": ["认真少玩笑", "偶尔打趣", "适量幽默", "经常幽默", "俏皮活跃"],
        "initiative": ["主要回应", "较少发起", "适度发起", "较常发起", "积极发起"],
        "directness": ["委婉表达", "偏委婉", "坦率兼顾分寸", "直白清晰", "直接但不冒犯"]
    ]
    static let fingerprintKeys = ["nickname", "avatar_asset", "birth_date", "gender_kind", "gender_text", "identity", "background", "native_language", "mbti", "baseline_traits", "sleep_start_minute", "sleep_end_minute"]

    static func calendar(_ zone: TimeZone = .current) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone; c.locale = Locale(identifier: "en_US_POSIX"); return c
    }
    static func civil(_ date: Date, zone: TimeZone = .current) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func birth(_ text: String, zone: TimeZone = .current) throws -> Date {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              let date = calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              civil(date, zone: zone) == text else { throw BionicFailure("invalidBirthDate") }
        return date
    }
    static func age(_ birthDate: String, now: Date = .now, zone: TimeZone = .current) throws -> Int {
        let c = calendar(zone)
        let start = try birth(birthDate, zone: zone)
        let today = try birth(civil(now, zone: zone), zone: zone)
        return c.dateComponents([.year], from: start, to: today).year ?? -1
    }
    static func birthdayRange(now: Date = .now) -> ClosedRange<Date> {
        let c = calendar(); let day = c.startOfDay(for: now)
        let lower = c.date(byAdding: .day, value: 1, to: c.date(byAdding: .year, value: -71, to: day)!)!
        let upper = c.date(byAdding: .year, value: -19, to: day)!
        return lower...upper
    }
    static func fingerprint(_ persona: BionicObject) throws -> String {
        let fields = Dictionary(uniqueKeysWithValues: fingerprintKeys.map { ($0, persona[$0] ?? .null) })
        return try BionicCodec.hash(fields)
    }
    static func validate(_ p: BionicObject, existing: BionicObject? = nil, importing: Bool = false, now: Date = .now) throws {
        try p.require(fingerprintKeys + ["current_traits", "evolution_enabled", "proactive_enabled", "context_limit", "output_limit", "timezone_policy"])
        let age = try age(p.text("birth_date"), now: now)
        guard age > 18, importing || (existing?.text("birth_date") == p.text("birth_date")) || age <= 70 else { throw BionicFailure("ageBoundary") }
        guard (1...20).contains(p.text("nickname").trimmingCharacters(in: .whitespacesAndNewlines).count), p.text("nickname").count <= 20,
              (1...120).contains(p.text("identity").trimmingCharacters(in: .whitespacesAndNewlines).count), p.text("identity").count <= 120,
              p["background"]?.string != nil, p.text("background").count <= 2000,
              ["none", "male", "female", "custom"].contains(p.text("gender_kind")),
              languages.contains(p.text("native_language")),
              p["mbti"] == .null || types.contains(p.text("mbti")),
              p["sleep_start_minute"]?.int != nil, p["sleep_end_minute"]?.int != nil,
              (0...1439).contains(p.int("sleep_start_minute")), (0...1439).contains(p.int("sleep_end_minute")),
              p.int("sleep_start_minute") != p.int("sleep_end_minute"),
              p.text("timezone_policy") == "follow_device", p["evolution_enabled"]?.bool != nil, p["proactive_enabled"]?.bool != nil,
              p.int("output_limit") >= 1024, p.int("context_limit") > p.int("output_limit") + 2048 else { throw BionicFailure("invalidFields") }
        if p.text("gender_kind") == "custom" {
            guard (1...20).contains(p.text("gender_text").count) else { throw BionicFailure("invalidFields", detail: "gender_text") }
        } else if p["gender_text"] != .null { throw BionicFailure("invalidFields", detail: "gender_text") }
        if let old = existing, old.text("native_language") != p.text("native_language") { throw BionicFailure("invalidFields", detail: "native_language") }
        if let asset = p.optionalText("avatar_asset") {
            guard asset.hasPrefix("assets/"), asset.hasSuffix(".png"), asset.count == 75,
                  asset.dropFirst(7).dropLast(4).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw BionicFailure("invalidFields", detail: "avatar_asset")
            }
        } else if p["avatar_asset"] != .null { throw BionicFailure("invalidFields") }
        for key in ["baseline_traits", "current_traits"] {
            let t = p.object(key)
            try t.require(dimensions, exact: true)
            guard dimensions.allSatisfy({ (1...5).contains(t.int($0)) }) else { throw BionicFailure("invalidFields", detail: key) }
        }
        for d in dimensions {
            guard abs(p.object("current_traits").int(d) - p.object("baseline_traits").int(d)) <= 2 else { throw BionicFailure("invalidFields", detail: d) }
        }
    }
    static func draft(language: String, now: Date = .now) -> BionicObject {
        let neutral = Dictionary(uniqueKeysWithValues: dimensions.map { ($0, BionicJSON.integer(3)) })
        let birthday = calendar().date(byAdding: .year, value: -25, to: now)!
        return ["persona_revision_id": .string(BionicCodec.id()), "character_id": .string(BionicCodec.id()),
                "recorded_at": .string(BionicCodec.instant(now)), "nickname": .string(""), "avatar_asset": .null,
                "birth_date": .string(civil(birthday)), "gender_kind": .string("none"), "gender_text": .null,
                "identity": .string(""), "background": .string(""), "native_language": .string(languages.contains(language) ? language : "zh-Hans"),
                "mbti": .null, "baseline_traits": .object(neutral), "current_traits": .object(neutral),
                "sleep_start_minute": .integer(60), "sleep_end_minute": .integer(480), "timezone_policy": .string("follow_device"),
                "evolution_enabled": .bool(false), "proactive_enabled": .bool(false), "context_limit": .integer(200000),
                "output_limit": .integer(8192), "validation_receipt": .null]
    }
    static func time(on day: Date, minute: Int, zone: TimeZone = .current) -> Date {
        let c = calendar(zone)
        return c.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day,
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)!
    }
    static func lastBoundary(_ p: BionicObject, now: Date, zone: TimeZone = .current) -> Date {
        let c = calendar(zone); let today = c.startOfDay(for: now)
        let candidate = time(on: today, minute: p.int("sleep_start_minute"), zone: zone)
        return candidate <= now ? candidate : time(on: c.date(byAdding: .day, value: -1, to: today)!, minute: p.int("sleep_start_minute"), zone: zone)
    }
    static func nextBoundary(_ p: BionicObject, now: Date, zone: TimeZone = .current) -> Date {
        let c = calendar(zone); let last = lastBoundary(p, now: now, zone: zone)
        return time(on: c.date(byAdding: .day, value: 1, to: last)!, minute: p.int("sleep_start_minute"), zone: zone)
    }
    static func sleepEnd(_ p: BionicObject, after start: Date, zone: TimeZone = .current) -> Date {
        let c = calendar(zone)
        let day = p.int("sleep_end_minute") > p.int("sleep_start_minute") ? start : c.date(byAdding: .day, value: 1, to: start)!
        return time(on: day, minute: p.int("sleep_end_minute"), zone: zone)
    }
    static func asleep(_ p: BionicObject, now: Date = .now, zone: TimeZone = .current) -> Bool {
        now < sleepEnd(p, after: lastBoundary(p, now: now, zone: zone), zone: zone)
    }
    static func dayBoundary(_ p: BionicObject, now: Date = .now) -> BionicObject {
        let boundary = lastBoundary(p, now: now)
        return ["day_key": .string(civil(boundary)), "boundary_at": .string(BionicCodec.instant(boundary)), "timezone": .string(TimeZone.current.identifier)]
    }
    static func logicalDate(_ message: BionicObject) throws -> String {
        guard let zone = TimeZone(identifier: message.text("recorded_timezone")) else { throw BionicFailure("archiveInvalid") }
        return civil(try BionicCodec.date(message.text("logical_at")), zone: zone)
    }
}
