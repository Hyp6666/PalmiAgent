import Foundation

@MainActor
enum BionicPersonaCreation {
    nonisolated static var schema: JSONValue {
        ToolJSONSchema.object(properties: [
            "nickname": ToolJSONSchema.string(description: "角色昵称，1到20字"),
            "identity": ToolJSONSchema.string(description: "身份设定，1到120字"),
            "birth_date": ToolJSONSchema.string(description: "真实合法的 YYYY-MM-DD；角色必须已满19岁且不超过70岁", format: "date"),
            "background": ToolJSONSchema.string(description: "背景，最多2000字；未给出时为空"),
            "native_language": ToolJSONSchema.string(description: "角色固定语言，默认应用语言，创建后不可直接改",
                enumValues: ["zh-Hans", "zh-Hant", "en", "ja", "ko"]),
            "participant_name": ToolJSONSchema.string(description: "当前用户希望角色如何称呼自己，默认当前语言的‘我’"),
            "gender_kind": ToolJSONSchema.string(description: "性别表达；默认none", enumValues: ["none", "male", "female", "custom"]),
            "gender_text": ToolJSONSchema.string(description: "仅gender_kind=custom时使用，1到20字"),
            "mbti": ToolJSONSchema.string(description: "可选的16型MBTI，留空则不设置"),
            "baseline_traits": ToolJSONSchema.object(
                properties: Dictionary(uniqueKeysWithValues: BionicPersonaCatalog.dimensions.map {
                    ($0, ToolJSONSchema.integer(description: "1到5"))
                }), required: BionicPersonaCatalog.dimensions),
            "sleep_start_minute": ToolJSONSchema.integer(description: "当地时间距零点的分钟数，0到1439；默认沿用创建页"),
            "sleep_end_minute": ToolJSONSchema.integer(description: "当地时间距零点的分钟数，0到1439；必须区别于入睡时间"),
            "reply_timing": ToolJSONSchema.string(description: "默认instant", enumValues: ["instant", "natural"]),
            "proactive_enabled": ToolJSONSchema.bool(description: "是否允许主动联系，默认false"),
            "evolution_enabled": ToolJSONSchema.bool(description: "是否启用既有人格演化，默认false"),
            "avatar_path": ToolJSONSchema.string(
                description: "可选。用户选定的工作区图片相对路径，不能是URL、绝对路径或虚构文件。头像未提供时省略本字段。"
            ),
            "avatar_crop": ToolJSONSchema.object(properties: [
                "center_x": ToolJSONSchema.number(description: "转正图片中的水平中心，0到1，左到右"),
                "center_y": ToolJSONSchema.number(description: "转正图片中的垂直中心，0到1，上到下"),
                "size": ToolJSONSchema.number(description: "正方形边长占转正图片短边的比例，大于0且不超过1")
            ], required: ["center_x", "center_y", "size"])
        ], required: ["nickname", "identity", "birth_date"])
    }

    static func normalizedArguments(_ arguments: ToolArguments) throws -> ToolArguments {
        let draft = try make(arguments, characterID: BionicCodec.id())
        var fields: BionicObject = [:]
        for key in ["nickname", "identity", "birth_date", "background", "native_language",
                    "gender_kind", "baseline_traits", "sleep_start_minute", "sleep_end_minute",
                    "reply_timing", "proactive_enabled", "evolution_enabled"] {
            guard let value = draft.persona[key] else {
                throw BionicFailure("invalidFields", detail: key)
            }
            fields[key] = value
        }
        fields["participant_name"] = .string(draft.participant.text("display_name"))
        if let value = draft.persona.optionalText("mbti") { fields["mbti"] = .string(value) }
        if let value = draft.persona.optionalText("gender_text") { fields["gender_text"] = .string(value) }
        if let avatar = try BionicAvatarImportSpec.parse(arguments) {
            fields["avatar_path"] = .string(avatar.path)
            if let crop = avatar.crop {
                fields["avatar_crop"] = .object([
                    "center_x": .number(crop.centerX),
                    "center_y": .number(crop.centerY),
                    "size": .number(crop.size)
                ])
            }
        }
        return try ToolArguments(jsonString: BionicCodec.string(fields))
    }

    static func make(_ arguments: ToolArguments, characterID: String,
                     now: Date = .now) throws -> (persona: BionicObject, participant: BionicObject) {
        let decoded = try JSONDecoder().decode(BionicJSON.self,
            from: Data(arguments.normalizedJSONString().utf8))
        guard case .object(let input) = decoded else { throw BionicFailure("invalidFields") }
        let allowed = Set(["nickname", "identity", "birth_date", "background", "native_language",
                           "participant_name", "gender_kind", "gender_text", "mbti", "baseline_traits",
                           "sleep_start_minute", "sleep_end_minute", "reply_timing", "proactive_enabled",
                           "evolution_enabled", "avatar_path", "avatar_crop"])
        guard Set(input.keys).isSubset(of: allowed), BionicCodec.validID(characterID) else {
            throw BionicFailure("invalidFields")
        }
        _ = try BionicAvatarImportSpec.parse(arguments)
        func string(_ key: String) throws -> String? {
            guard let value = input[key] else { return nil }
            guard case .string(let text) = value else { throw BionicFailure("invalidFields", detail: key) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let language = try string("native_language") ?? PalmiLanguage.current.rawValue
        var persona = BionicPersonaCatalog.draft(language: language, now: now)
        persona["character_id"] = .string(characterID)
        for key in ["nickname", "identity", "birth_date"] {
            guard let text = try string(key), !text.isEmpty else { throw BionicFailure("invalidFields", detail: key) }
            persona[key] = .string(text)
        }
        for key in ["background", "gender_kind", "reply_timing"] {
            if let text = try string(key) { persona[key] = .string(text) }
        }
        let customGender = try string("gender_text")
        persona["gender_text"] = persona.text("gender_kind") == "custom" ? .text(customGender) : .null
        if let mbti = try string("mbti") { persona["mbti"] = mbti.isEmpty ? .null : .string(mbti.uppercased()) }
        for key in ["sleep_start_minute", "sleep_end_minute"] {
            if let value = input[key] {
                guard case .integer(let number) = value, (0...1439).contains(number) else {
                    throw BionicFailure("invalidFields", detail: key)
                }
                persona[key] = value
            }
        }
        for key in ["proactive_enabled", "evolution_enabled"] {
            if let value = input[key] {
                guard case .bool = value else { throw BionicFailure("invalidFields", detail: key) }
                persona[key] = value
            }
        }
        if let value = input["baseline_traits"] {
            guard case .object(let traits) = value,
                  Set(traits.keys) == Set(BionicPersonaCatalog.dimensions),
                  traits.values.allSatisfy({ value in
                      if case .integer(let n) = value { return (1...5).contains(n) }
                      return false
                  }) else { throw BionicFailure("invalidFields", detail: "baseline_traits") }
            persona["baseline_traits"] = value
            persona["current_traits"] = value
        }
        try BionicPersonaCatalog.validate(persona)
        let name = try string("participant_name") ?? PalmiL10n.tr("bionic.creation.defaultParticipant")
        guard (1...40).contains(name.count) else { throw BionicFailure("invalidFields", detail: "participant_name") }
        let participant: BionicObject = [
            "participant_id": .string(BionicCodec.id()), "display_name": .string(name),
            "avatar_asset": .null, "created_at": .string(BionicCodec.instant(now))
        ]
        return (persona, participant)
    }
}
