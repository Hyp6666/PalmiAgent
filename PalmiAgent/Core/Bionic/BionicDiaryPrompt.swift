import Foundation

extension BionicPromptBuilder {
    static let diaryInstructions = """
    你为角色自己写一篇当天的私人日记，不给用户发消息。用角色母语、第一人称写自然连贯的生活记录，中文约400字，其他语言保持相近篇幅。不写标题、日期抬头、执行说明或思考过程。
    人设规定你的身份、性格和生活背景。可以具体描写属于你这个虚构角色的日常生活、见闻和情绪，形成前后连贯的小细节；它们是角色故事，不是真实世界已验证的事实。不制造重大突变、现实订单、已经执行的工具操作或替用户办成事情。
    当天对话是唯一真实的交往证据。只有用户确实说过的事情才能写成用户事实；没聊天的时段只描述你自己的生活，不替用户补行踪、关系、心理或承诺。不把待发草稿当成已经聊过，不把其它参与者的经历归给当前用户。
    参考较早日记保持角色生活连续，但不把日记虚构升级成用户记忆。补写时只写指定日，不利用之后的聊天倒填那天的见闻。当天尚未结束时，不声称已经经历写作时刻之后的事件。
    source_kind=character_fiction 由宿主标记，正文不要解释这个字段。只调用 write_diary，text 是整篇日记。不得调用 speak、generate_image、recall 或其它工具。
    """

    static func diary(_ role: BionicRole, archive: BionicArchiveStore,
                      day: String, zone: TimeZone, now: Date = .now) async throws -> BionicModelInput {
        guard BionicDiaryCalendar.date(day, zone: zone) != nil,
              day <= BionicDiaryCalendar.lastDueDay(now: now, zone: zone) else {
            throw BionicFailure("invalidFields")
        }
        let page = try await archive.search(role.installationID,
            query: ["query": .null, "from_date": .string(day), "through_date": .string(day),
                    "message_ids": .array([]), "cursor": .null],
            includeMemories: false, maximumBytes: 12_000)
        let previous = try await archive.diaryEntries(role.installationID).filter { $0.day < day }
        var transcript = page.items
        var preceding = Array(previous.suffix(3))
        while true {
            let source: BionicObject = [
                "day_key": .string(day), "timezone": .string(zone.identifier),
                "written_at": .string(BionicCodec.instant(now)),
                "character_id": .string(role.characterID),
                "real_dialogue": .records(transcript),
                "dialogue_is_complete": .bool(page.cursor == nil && transcript.count == page.items.count),
                "earlier_character_diaries": .records(preceding.map(\.object))
            ]
            let input = BionicModelInput(messages: [
                module("diary_rules", diaryInstructions),
                module("persona", try BionicCodec.string(personaData(role, now: now))),
                tail("diary_source", try BionicCodec.string(source))
            ], tools: ["write_diary"], output: min(1600, role.persona.int("output_limit")),
               context: role.persona.int("context_limit"))
            do { try checkBudget(input); return input }
            catch BionicControl.capacity {
                if !transcript.isEmpty { transcript.removeFirst(); continue }
                if !preceding.isEmpty { preceding.removeFirst(); continue }
                throw BionicControl.capacity
            }
        }
    }

    static func diaryCompaction(_ role: BionicRole, previous: BionicObject?,
                                entries: [BionicDiaryEntry]) throws -> BionicModelInput {
        let rules = """
        维护既有压缩摘要。保留 previous_summary 中有效的真实对话信息、人物归属、边界和未完事项，不重新发明用户事实。
        把 new_diaries 中以后可能有用的角色生活细节压缩到摘要内独立的“角色生活（日记虚构）”段。保留必要的日期和前后连续性；不要逐篇复述，不把日记内容混成真实共同经历。不写新的故事。
        memory_changes 必须为 []。日记只能贡献带有虚构归属的角色生活摘要，不能在本动作创建、修改或删除任何事实记忆。
        使用 native_language，控制整份 summary 接近 summary_target_tokens 的预算。只调用 context_pro_max_plus。
        """
        let data: BionicObject = [
            "native_language": role.persona["native_language"] ?? .null,
            "previous_summary": previous?["text"] ?? .null,
            "new_diaries": .records(entries.map(\.object)),
            "summary_target_tokens": .count(summaryTarget(role.persona.int("output_limit")))
        ]
        let input = BionicModelInput(messages: [module("diary_compaction", rules),
            tail("diary_source", try BionicCodec.string(data))],
            tools: ["context_pro_max_plus"], output: role.persona.int("output_limit"),
            context: role.persona.int("context_limit"))
        try checkBudget(input)
        return input
    }
}
