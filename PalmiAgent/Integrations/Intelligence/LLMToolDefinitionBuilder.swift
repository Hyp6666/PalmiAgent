import Foundation

@MainActor
enum LLMToolDefinitionBuilder {
    static func makeToolDefinitions(for actions: [ToolAction]) -> [AgentModelToolDefinition] {
        let actionsByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        return AgentExternalToolFacadeCatalog.availableFacades(from: actions).compactMap { facade in
            makeToolDefinition(for: facade, actionsByID: actionsByID)
        }
    }

    static func makeToolDefinition(for action: ToolAction) -> AgentModelToolDefinition {
        AgentModelToolDefinition(
            function: AgentModelFunctionDefinition(
                name: action.id.modelToolName,
                description: toolDescription(for: action),
                parameters: toolParametersSchema(for: action)
            )
        )
    }

    private static func makeToolDefinition(
        for facade: AgentExternalToolFacade,
        actionsByID: [ToolActionID: ToolAction]
    ) -> AgentModelToolDefinition? {
        let backingActions = facade.backingActionIDs.compactMap { actionsByID[$0] }
        guard backingActions.count == facade.backingActionIDs.count,
              let primaryAction = backingActions.first else {
            return nil
        }
        return AgentModelToolDefinition(
            function: AgentModelFunctionDefinition(
                name: facade.modelToolName,
                description: facadeDescription(
                    for: facade,
                    backingActions: backingActions
                ),
                parameters: facadeParametersSchema(for: facade, primaryAction: primaryAction)
            )
        )
    }

    private static func facadeDescription(
        for facade: AgentExternalToolFacade,
        backingActions: [ToolAction]
    ) -> String {
        var lines: [String]
        switch facade.name {
        case .read:
            lines = [
                "[工作区] 读取单个工作区文件的可读文本。长内容可通过 mode、focus、offset 和 chunk_size 定点读取；目录浏览使用 workspace(operation=list)。"
            ]
        case .edit:
            lines = [
                "[工作区] 编辑文本文件。operation=write 时创建或覆盖文件，operation=append 时在文件末尾追加内容。",
                "这是通用工作区工具，不要用它模拟通知、闹钟、地图、短信、电话、邮件或在线搜索。"
            ]
        case .workspace:
            lines = [
                "[工作区] 查看目录结构，或创建目录、删除、移动、重命名、复制和检查工作区项目。通过 operation 选择具体动作。",
                "operation=list 用于目录列表、递归目录树或批量读取；其他 operation 用于路径管理。"
            ]
        case .python:
            lines = [
                "[计算] 执行真实 CPython 3.14 脚本。只用于代码、已知数据的计算与转换，不得模拟网页、系统或个人数据工具。",
                "支持标准库、内置 workspace 模块和随 app 提供的 Python 包；不支持 pip 动态安装、系统进程、GUI 或长期阻塞任务。"
            ]
        case .ocr:
            lines = [
                "[图片] 对工作区图片执行 OCR，并写出文本与结构化结果。只用于提取图片文字；通用画面理解优先使用 vision。"
            ]
        case .vision:
            lines = [
                "[图片] 使用当前会话配置的多模态模型理解一张工作区图片。传入图片相对路径和具体视觉问题；只提取文字时使用 ocr。"
            ]
        case .webSearch:
            lines = [
                "[网页] 搜索候选网页并返回标题、规范化 URL 和摘要。它用于发现来源，不读取正文；关键事实继续用 fetch 读取高价值来源。"
            ]
        case .fetch:
            lines = [
                "[网页] 读取一个或多个已知 URL 的实际内容，支持网页、PDF、文本、JSON 和 XML。用户已经给出 URL 时直接调用。"
            ]
        case .systemTime:
            lines = [
                "[设备] 获取设备当前本地日期、时间和时区。涉及今天、明天、相对日期或当前时间时先调用。"
            ]
        case .location:
            lines = [
                "[设备] 在任务确实依赖这里、附近或当前位置时获取定位并反向地理编码。"
            ]
        }
        return lines.joined(separator: "\n")
    }

    private static func facadeParametersSchema(
        for facade: AgentExternalToolFacade,
        primaryAction: ToolAction
    ) -> JSONValue {
        switch facade.name {
        case .edit:
            return ToolJSONSchema.object(
                properties: [
                    "operation": ToolJSONSchema.string(
                        description: "必填。write 创建或覆盖文件；append 在文件末尾追加内容。",
                        enumValues: ["write", "append"]
                    ),
                    "path": ToolJSONSchema.string(description: "必填。工作区内的相对文件路径。"),
                    "content": ToolJSONSchema.string(description: "必填。要写入或追加的文本内容。")
                ],
                required: ["operation", "path", "content"]
            )
        case .workspace:
            return ToolJSONSchema.object(
                properties: [
                    "operation": ToolJSONSchema.string(
                        description: "必填。list 查看目录；其他值执行对应的路径管理动作。",
                        enumValues: ["list", "mkdir", "delete", "move", "rename", "copy", "info", "exists"]
                    ),
                    "path": ToolJSONSchema.string(description: "可选。目标相对路径；list 默认工作区根目录，其他操作必填。"),
                    "destination": ToolJSONSchema.string(description: "可选。move、rename、copy 操作必填的目标相对路径。"),
                    "recursive": ToolJSONSchema.bool(description: "可选。list 是否递归输出目录树，默认 true。"),
                    "include_content": ToolJSONSchema.bool(description: "可选。list 是否同时读取可读文本内容，默认 false。"),
                    "max_chars": ToolJSONSchema.integer(description: "可选。include_content=true 时总输出最大字符数，默认 20000。"),
                    "max_files": ToolJSONSchema.integer(description: "可选。include_content=true 时最多展开的文件数，默认 64。"),
                    "mode": ToolJSONSchema.string(
                        description: "可选。include_content=true 时的读取模式。",
                        enumValues: WorkspaceReadMode.allCases.map(\.rawValue)
                    ),
                    "focus": ToolJSONSchema.string(description: "可选。include_content=true 时围绕该主题抽取相关片段。")
                ],
                required: ["operation"]
            )
        default:
            return toolParametersSchema(for: primaryAction)
        }
    }

    private static func enabledWebSearchProviderEnumValues() -> [String] {
        WebSearchProviderSettings.enabledProviderIDs().map(\.rawValue)
    }

    private static func toolDescription(for action: ToolAction) -> String {
        var lines = [
            "[\(action.category.title)] \(action.title)：\(action.effect)",
            action.details
        ]

        if action.id == .detectWebSearchProviders {
            lines.append("当前设置开启的搜索源：\(WebSearchProviderSettings.enabledProviderIDsDescription())")
        }

        if let routingHint = routingHint(for: action.id) {
            lines.append("选择规则：\(routingHint)")
        }

        if action.availability != .live {
            lines.append("状态：\(action.availability.title)")
        }

        return lines.joined(separator: "\n")
    }

    private static func routingHint(for actionID: ToolActionID) -> String? {
        switch actionID {
        case .runPython:
            return "只在用户明确需要编写/运行 Python，或你已经拿到了完整输入数据且需要计算/转换时使用。不要用它替代闹钟、地图、通知、短信、日历、联系人或网页搜索，也不要用它编造现实世界数据。文件操作请优先使用 read、edit、workspace。"
        case .recognizeImageText:
            return "用户明确要求提取图片文字，或 vision 不可用、失败、结果有歧义时使用。它只处理工作区内已有图片路径；若用户刚上传附件，从“附件：”块里取相对路径作为 path。"
        case .scanImageWithMultimodalModel:
            return "任务需要理解图片画面而不只是提取文字时使用。必须传工作区图片相对路径 path 和具体 prompt；若当前会话没有可用多模态模型，随后可用 ocr 对同一路径提取文字。"
        case .fileWrite, .fileAppend:
            return "这是通用工作区工具，不是系统能力替身。不要用它模拟通知、闹钟、地图、短信、电话、邮件或在线搜索。"
        case .fileRead:
            return "读取工作区内单个文件的可读文本。长文档优先围绕当前目标抽取关键事实；需要定点阅读时，使用 mode、focus、offset、chunk_size 控制读取范围。读取目录或批量浏览文件请使用 workspace(operation=list)。"
        case .listDirectory:
            return "对应 workspace(operation=list)：查看目录结构和文件列表；设置 include_content=true 可批量读取目录下所有可读文本文件的内容。"
        case .fileManage:
            return "对应 workspace 的路径管理 operation：创建目录、删除、移动、重命名、复制、查看信息或检查存在。"
        case .getCurrentDateTime:
            return "凡是涉及今天、明天、下周、几点、哪一天、创建日程、提醒、通知、闹钟、倒计时或任何相对时间表达时，都应优先先调用它确认当前本地时间。"
        case .requestAlarmPermission, .listAlarms, .createAlarm, .createClockTimer, .manageAlarm:
            return "这是系统时钟/闹钟能力。需要真正的系统闹钟时优先使用它，不要退回到本地通知或 Python 模拟。"
        case .requestLocation:
            return "仅当任务真的依赖当前位置时再调用，不要把定位当默认第一步；但如果用户说这里、附近、我这、离我最近、本地等明显依赖当前位置的表达，就应优先先定位。"
        case .detectWebSearchProviders:
            return "只在用户明确要求检测网络/搜索源，或上一次搜索失败后使用。它不返回搜索结果，只返回环境探测。"
        case .searchWeb:
            return "用于发现候选来源，只返回标题、规范化 URL 和摘要，不读取正文。涉及当前事实或未知网址时先搜索；调用前把用户需求整理成尽可能简短、自然且语义完整的检索短语，不要照抄整段问题，也不要机械拆成零散关键词；得到候选后选择少量高价值来源调用网页浏览。不要把搜索摘要当作关键事实的最终证据。"
        case .fetchStaticWebPage:
            return "用于读取已知 URL 的实际内容。内部会根据 Content-Type 处理 HTML、JavaScript 页面、PDF、纯文本、JSON 和 XML，并返回最终重定向 URL、元数据和结构化正文。用户已给出 URL 时直接调用，不要先重复搜索。"
        case .openInAppBrowser:
            return "用于把外部网页或刚生成的工作区 HTML 交给用户继续交互。生成小游戏、交互式海报、可视化网页等作品时，除非用户或技能指定路径，推荐把入口放在 artifacts/<短名称>/index.html，图片/CSS/JS 等资源放同目录子目录；调用时传工作区相对路径和可读 title，最终回复也给出入口文件的 Markdown 链接。"
        case .openMapsRoute:
            return "它只负责打开 Apple 地图展示地点或路线，不提供跨城交通方案优化、实时票价或时刻表计算。"
        case .sendLocalNotification:
            return "它创建的是本应用本地通知，不是系统时钟闹钟；如果用户要真正的系统闹钟，应优先用系统闹钟工具。"
        default:
            return nil
        }
    }

    static func toolParametersSchema(for action: ToolAction) -> JSONValue {
        switch action.id {
        case .fileRead:
            return ToolJSONSchema.object(
                properties: [
                    "path": ToolJSONSchema.string(description: "必填。要读取的文件相对路径。"),
                    "mode": ToolJSONSchema.string(description: "可选。读取模式。`auto` 默认；`head` 读开头；`tail` 读结尾；`chunk` 从 offset 开始读一段；`section` 围绕 focus 读相关片段；`abstract` 优先提取摘要/概要段。", enumValues: WorkspaceReadMode.allCases.map(\.rawValue)),
                    "offset": ToolJSONSchema.integer(description: "可选。`chunk` 模式下从第几个字符开始读取，默认 0。"),
                    "chunk_size": ToolJSONSchema.integer(description: "可选。单次返回的目标字符数。未传时使用 max_chars。"),
                    "focus": ToolJSONSchema.string(description: "可选。`section` 或 `auto` 模式下围绕该关键词/主题提取相关片段。"),
                    "query": ToolJSONSchema.string(description: "可选。`focus` 的同义参数。"),
                    "max_chars": ToolJSONSchema.integer(description: "可选。总输出最大字符数，默认 20000。")
                ],
                required: ["path"]
            )
        case .fileWrite:
            return ToolJSONSchema.object(
                properties: [
                    "path": ToolJSONSchema.string(description: "必填。要写入的文件相对路径，例如 README.md、script.py、data.json。"),
                    "content": ToolJSONSchema.string(description: "必填。文件内容。")
                ],
                required: ["path", "content"]
            )
        case .fileAppend:
            return ToolJSONSchema.object(
                properties: [
                    "path": ToolJSONSchema.string(description: "必填。要追加内容的文件相对路径。"),
                    "content": ToolJSONSchema.string(description: "必填。要追加的文本内容。")
                ],
                required: ["path", "content"]
            )
        case .listDirectory:
            return ToolJSONSchema.object(
                properties: [
                    "path": ToolJSONSchema.string(description: "可选。要查看的目录相对路径，默认是工作区根目录。"),
                    "recursive": ToolJSONSchema.bool(description: "可选。是否递归输出目录树。默认 true。"),
                    "include_content": ToolJSONSchema.bool(description: "可选。是否同时读取目录下所有可读文本文件的内容。默认 false。"),
                    "max_chars": ToolJSONSchema.integer(description: "可选。include_content=true 时总输出最大字符数，默认 20000。"),
                    "max_files": ToolJSONSchema.integer(description: "可选。include_content=true 时最多展开多少个文件，默认 64。"),
                    "mode": ToolJSONSchema.string(description: "可选。include_content=true 时的读取模式。", enumValues: WorkspaceReadMode.allCases.map(\.rawValue)),
                    "focus": ToolJSONSchema.string(description: "可选。include_content=true 时围绕该关键词抽取相关片段。")
                ]
            )
        case .fileManage:
            return ToolJSONSchema.object(
                properties: [
                    "operation": ToolJSONSchema.string(description: "必填。要执行的操作。", enumValues: ["mkdir", "delete", "move", "rename", "copy", "info", "exists"]),
                    "path": ToolJSONSchema.string(description: "必填。目标路径（所有操作都需要）。"),
                    "destination": ToolJSONSchema.string(description: "move/rename/copy 操作必填。目标位置的相对路径。")
                ],
                required: ["operation", "path"]
            )
        case .runPython:
            return ToolJSONSchema.object(
                properties: [
                    "script_path": ToolJSONSchema.string(description: "可选。工作区内已有的 .py 相对路径。"),
                    "script": ToolJSONSchema.string(description: "可选。直接执行的内联 Python 源码。和 script_path 二选一。"),
                    "save_to": ToolJSONSchema.string(description: "可选。执行内联 Python 时，先保存到工作区的相对路径。")
                ],
                description: "执行真实 CPython 3.14 脚本。优先使用标准库、内置 workspace 模块和以下预装纯 Python 包：\(PythonPackageCatalog.supportedImportsSentence)。\(PythonPackageCatalog.toolingSummary) 不要依赖 pip 动态装包、系统进程、GUI、长期阻塞任务或任何未列出的第三方库。文件操作请优先使用 read、edit、workspace。"
            )
        case .recognizeImageText:
            return ToolJSONSchema.object(
                properties: [
                    "path": ToolJSONSchema.string(description: "必填。工作区内图片文件的相对路径，通常来自用户上传附件块，例如 .files/uploads/.../original/photo.jpg。"),
                    "output_directory": ToolJSONSchema.string(description: "可选。OCR 输出目录。未传时，附件图片写入同批次 extracted 目录，其他图片写入 .files/ocr。"),
                    "recognition_languages": ToolJSONSchema.stringArray(description: "可选。识别语言列表，默认 [\"zh-Hans\", \"en-US\"]。"),
                    "uses_language_correction": ToolJSONSchema.bool(description: "可选。是否启用语言纠错，默认 true。")
                ],
                required: ["path"],
                description: "使用随包集成的 PP-OCRv6 Tiny 模型资源执行图片 OCR，并写出 .ocr.txt 与 .ocr.json。"
            )
        case .scanImageWithMultimodalModel:
            return ToolJSONSchema.object(
                properties: [
                    "path": ToolJSONSchema.string(description: "必填。工作区内图片文件的相对路径，通常来自用户上传附件块，例如 .files/uploads/.../original/photo.jpg。"),
                    "prompt": ToolJSONSchema.string(description: "必填。发给多模态模型的具体视觉理解指令，例如“请描述图片内容并指出关键物体”。")
                ],
                required: ["path", "prompt"],
                description: "调用当前会话配置的多模态模型理解一张工作区图片，并返回文本结果。"
            )
        case .detectWebSearchProviders:
            return ToolJSONSchema.object(
                properties: [
                    "source": ToolJSONSchema.string(description: "可选。只探测某一个搜索源；不填则探测当前设置中开启的全部搜索源。", enumValues: enabledWebSearchProviderEnumValues())
                ]
            )
        case .searchWeb:
            return ToolJSONSchema.object(
                properties: [
                    "query": ToolJSONSchema.string(
                        description: "必填。根据用户需求生成一个尽可能简短、自然且语义完整的检索短语。使用尽可能少但足以准确表达目标的词语，保留专有名词、产品名、年份、版本号、函数名、错误信息、地点等关键限定，以及表达它们关系所必需的连接词；删除寒暄、请求语气、回答格式和无关背景。不要直接复制用户整段问题，也不要机械拆成互不连贯的关键词。一次只表达一个明确的检索目标；技术名称和错误信息保留原始语言，其他内容使用最适合目标资料的自然语言。只返回标题、URL 和摘要。"
                    ),
                    "source": ToolJSONSchema.string(
                        description: "可选。搜索源；只能填写当前设置中开启的值。不填时使用默认搜索源。",
                        enumValues: enabledWebSearchProviderEnumValues()
                    ),
                    "max_results": ToolJSONSchema.integer(
                        description: "可选。希望返回的候选数，最小 1；超过当前 Agent 档位上限时自动降至档位上限。"
                    )
                ],
                required: ["query"]
            )
        case .fetchStaticWebPage:
            return ToolJSONSchema.object(
                properties: [
                    "url": ToolJSONSchema.string(
                        description: "可选。要读取的单个 http/https URL。和 urls 二选一。",
                        format: "uri"
                    ),
                    "urls": ToolJSONSchema.stringArray(
                        description: "可选。要读取的多个 http/https URL。单次最多 10 个。"
                    ),
                    "max_chars": ToolJSONSchema.integer(
                        description: "可选。每个网页希望返回的正文字符上限。未传时使用当前档位建议值，绝对上限 100000。"
                    ),
                    "focus": ToolJSONSchema.string(
                        description: "可选。需要重点查找的问题、关键词或主题。提供后会优先返回相关正文块及上下文。"
                    ),
                    "include_links": ToolJSONSchema.bool(
                        description: "可选。是否返回正文中的相关链接，默认 true。"
                    )
                ]
            )
        case .fetchWebBatch, .saveWebPageToWorkspace:
            return ToolJSONSchema.object(properties: [:])
        case .openInAppBrowser:
            return ToolJSONSchema.object(
                properties: [
                    "url": ToolJSONSchema.string(description: "必填。要在应用内浏览器中打开的 URL 或工作区相对路径。打开刚生成的 HTML 时优先传工作区相对路径。"),
                    "title": ToolJSONSchema.string(description: "可选。浏览器顶部显示的网页或作品名称。打开自己生成的交互网页时，优先传作品标题。"),
                    "reader_mode": ToolJSONSchema.bool(description: "可选。是否优先进入 Reader Mode。默认 false。"),
                    "bar_collapsing_enabled": ToolJSONSchema.bool(description: "可选。是否启用地址栏折叠。默认 false。")
                ],
                required: ["url"]
            )
        case .createCalendarEvent:
            return ToolJSONSchema.object(
                properties: [
                    "title": ToolJSONSchema.string(description: "必填。事件标题。"),
                    "notes": ToolJSONSchema.string(description: "可选。事件备注。"),
                    "start_at": ToolJSONSchema.string(description: "必填。开始时间，ISO8601。", format: "date-time"),
                    "end_at": ToolJSONSchema.string(description: "必填。结束时间，ISO8601。", format: "date-time"),
                    "calendar_title": ToolJSONSchema.string(description: "可选。要写入的日历名称。"),
                    "location": ToolJSONSchema.string(description: "可选。事件地点。"),
                    "url": ToolJSONSchema.string(description: "可选。事件关联链接。", format: "uri"),
                    "is_all_day": ToolJSONSchema.bool(description: "可选。是否为全天事件。默认 false。"),
                    "time_zone_identifier": ToolJSONSchema.string(description: "可选。事件时区，例如 Asia/Shanghai。"),
                    "recurrence_frequency": ToolJSONSchema.string(description: "可选。重复频率。", enumValues: ["daily", "weekly", "monthly", "yearly"]),
                    "recurrence_interval": ToolJSONSchema.integer(description: "可选。重复间隔，默认 1。"),
                    "recurrence_end_at": ToolJSONSchema.string(description: "可选。重复结束时间，ISO8601。", format: "date-time"),
                    "alarm_minutes_before": ToolJSONSchema.integerArray(description: "可选。相对开始时间提前多少分钟提醒，例如 [10, 60]。"),
                    "alarm_at": ToolJSONSchema.string(description: "可选。绝对提醒时间，ISO8601。", format: "date-time")
                ],
                required: ["title", "start_at", "end_at"]
            )
        case .listTodayEvents:
            return ToolJSONSchema.object(
                properties: [
                    "start_at": ToolJSONSchema.string(description: "可选。查询起始时间，ISO8601。默认今天 00:00。", format: "date-time"),
                    "end_at": ToolJSONSchema.string(description: "可选。查询结束时间，ISO8601。默认明天 00:00。", format: "date-time"),
                    "limit": ToolJSONSchema.integer(description: "可选。最多返回多少条事件。"),
                    "calendar_title": ToolJSONSchema.string(description: "可选。只看某个日历。"),
                    "query": ToolJSONSchema.string(description: "可选。按标题、备注、地点或 URL 过滤。"),
                    "include_notes": ToolJSONSchema.bool(description: "可选。是否在结果里附带备注。默认 false。"),
                    "include_location": ToolJSONSchema.bool(description: "可选。是否在结果里附带地点。默认 true。"),
                    "include_calendar": ToolJSONSchema.bool(description: "可选。是否在结果里附带日历名。默认 true。"),
                    "include_url": ToolJSONSchema.bool(description: "可选。是否在结果里附带 URL。默认 false。")
                ]
            )
        case .createReminder:
            return ToolJSONSchema.object(
                properties: [
                    "title": ToolJSONSchema.string(description: "必填。提醒标题。"),
                    "notes": ToolJSONSchema.string(description: "可选。提醒备注。"),
                    "due_at": ToolJSONSchema.string(description: "可选。截止时间，ISO8601。", format: "date-time"),
                    "list_title": ToolJSONSchema.string(description: "可选。要写入的提醒列表名称。"),
                    "priority": ToolJSONSchema.integer(description: "可选。优先级 0-9。"),
                    "url": ToolJSONSchema.string(description: "可选。提醒关联链接。", format: "uri"),
                    "alarm_at": ToolJSONSchema.string(description: "可选。提醒触发时间，ISO8601。", format: "date-time"),
                    "recurrence_frequency": ToolJSONSchema.string(description: "可选。重复频率。", enumValues: ["daily", "weekly", "monthly", "yearly"]),
                    "recurrence_interval": ToolJSONSchema.integer(description: "可选。重复间隔，默认 1。"),
                    "recurrence_end_at": ToolJSONSchema.string(description: "可选。重复结束时间，ISO8601。", format: "date-time")
                ],
                required: ["title"]
            )
        case .listReminders:
            return ToolJSONSchema.object(
                properties: [
                    "status": ToolJSONSchema.string(description: "可选。筛选提醒状态。", enumValues: ["incomplete", "completed", "all"]),
                    "limit": ToolJSONSchema.integer(description: "可选。最多返回多少条提醒。"),
                    "list_title": ToolJSONSchema.string(description: "可选。只看某个提醒列表。"),
                    "query": ToolJSONSchema.string(description: "可选。按标题、备注或 URL 过滤。"),
                    "due_start_at": ToolJSONSchema.string(description: "可选。截止时间下界，ISO8601。", format: "date-time"),
                    "due_end_at": ToolJSONSchema.string(description: "可选。截止时间上界，ISO8601。", format: "date-time"),
                    "include_notes": ToolJSONSchema.bool(description: "可选。是否在结果里附带备注。默认 false。"),
                    "include_list": ToolJSONSchema.bool(description: "可选。是否在结果里附带列表名。默认 true。"),
                    "include_url": ToolJSONSchema.bool(description: "可选。是否在结果里附带 URL。默认 false。")
                ]
            )
        case .createContact:
            return ToolJSONSchema.object(
                properties: [
                    "given_name": ToolJSONSchema.string(description: "可选。名。"),
                    "family_name": ToolJSONSchema.string(description: "可选。姓。"),
                    "middle_name": ToolJSONSchema.string(description: "可选。中间名。"),
                    "nickname": ToolJSONSchema.string(description: "可选。昵称。"),
                    "organization": ToolJSONSchema.string(description: "可选。公司或组织。"),
                    "job_title": ToolJSONSchema.string(description: "可选。职位。"),
                    "department": ToolJSONSchema.string(description: "可选。部门。"),
                    "phones": ToolJSONSchema.stringArray(description: "可选。电话号码数组。"),
                    "emails": ToolJSONSchema.stringArray(description: "可选。邮箱数组。"),
                    "phones_labeled": ToolJSONSchema.objectArray(
                        description: "可选。带标签的电话号码数组。",
                        properties: [
                            "label": ToolJSONSchema.string(description: "可选。标签，例如 mobile、home、work。"),
                            "value": ToolJSONSchema.string(description: "必填。电话号码。")
                        ],
                        required: ["value"]
                    ),
                    "emails_labeled": ToolJSONSchema.objectArray(
                        description: "可选。带标签的邮箱数组。",
                        properties: [
                            "label": ToolJSONSchema.string(description: "可选。标签，例如 work、home。"),
                            "value": ToolJSONSchema.string(description: "必填。邮箱地址。")
                        ],
                        required: ["value"]
                    ),
                    "urls_labeled": ToolJSONSchema.objectArray(
                        description: "可选。带标签的网址数组。",
                        properties: [
                            "label": ToolJSONSchema.string(description: "可选。标签，例如 homepage。"),
                            "value": ToolJSONSchema.string(description: "必填。URL。", format: "uri")
                        ],
                        required: ["value"]
                    ),
                    "addresses": ToolJSONSchema.objectArray(
                        description: "可选。地址数组。",
                        properties: [
                            "label": ToolJSONSchema.string(description: "可选。标签，例如 home、work。"),
                            "street": ToolJSONSchema.string(description: "可选。街道。"),
                            "city": ToolJSONSchema.string(description: "可选。城市。"),
                            "state": ToolJSONSchema.string(description: "可选。省/州。"),
                            "postal_code": ToolJSONSchema.string(description: "可选。邮编。"),
                            "country": ToolJSONSchema.string(description: "可选。国家。"),
                            "iso_country_code": ToolJSONSchema.string(description: "可选。国家 ISO 代码，例如 CN。")
                        ]
                    ),
                    "birthday_at": ToolJSONSchema.string(description: "可选。生日，ISO8601。", format: "date-time"),
                    "note": ToolJSONSchema.string(description: "可选。备注。")
                ]
            )
        case .searchContacts:
            return ToolJSONSchema.object(
                properties: [
                    "keyword": ToolJSONSchema.string(description: "必填。要搜索的联系人关键字。"),
                    "limit": ToolJSONSchema.integer(description: "可选。最多返回多少个联系人。"),
                    "scope": ToolJSONSchema.string(description: "可选。搜索范围。默认 name。", enumValues: ["name", "phone", "email", "organization", "note", "address", "url", "all"]),
                    "include_details": ToolJSONSchema.bool(description: "可选。是否返回电话、邮箱、组织等详情。默认 true。")
                ],
                required: ["keyword"]
            )
        case .getCurrentDateTime:
            return ToolJSONSchema.object(properties: [:])
        case .requestAlarmPermission:
            return ToolJSONSchema.object(properties: [:])
        case .listAlarms:
            return ToolJSONSchema.object(
                properties: [
                    "limit": ToolJSONSchema.integer(description: "可选。最多返回多少个闹钟，默认 50。")
                ]
            )
        case .createAlarm:
            return ToolJSONSchema.object(
                properties: [
                    "title": ToolJSONSchema.string(description: "可选。闹钟标题。"),
                    "fixed_at": ToolJSONSchema.string(description: "可选。创建固定时间闹钟，ISO8601。和 hour/minute 二选一。", format: "date-time"),
                    "hour": ToolJSONSchema.integer(description: "可选。相对闹钟的小时，0-23。"),
                    "minute": ToolJSONSchema.integer(description: "可选。相对闹钟的分钟，0-59。"),
                    "weekdays": ToolJSONSchema.stringArray(description: "可选。重复星期数组，可填 1-7、monday、周一 等；不填表示不重复。"),
                    "sound_name": ToolJSONSchema.string(description: "可选。app 内自定义声音文件名；不填时用系统默认声音。")
                ]
            )
        case .createClockTimer:
            return ToolJSONSchema.object(
                properties: [
                    "title": ToolJSONSchema.string(description: "可选。倒计时标题。"),
                    "duration_seconds": ToolJSONSchema.number(description: "必填。倒计时秒数。"),
                    "sound_name": ToolJSONSchema.string(description: "可选。app 内自定义声音文件名；不填时用系统默认声音。")
                ],
                required: ["duration_seconds"]
            )
        case .manageAlarm:
            return ToolJSONSchema.object(
                properties: [
                    "alarm_id": ToolJSONSchema.string(description: "必填。闹钟 ID，必须来自查看系统闹钟工具。"),
                    "operation": ToolJSONSchema.string(description: "可选。默认 cancel。", enumValues: ["cancel", "pause", "resume", "continue", "stop"])
                ],
                required: ["alarm_id"]
            )
        case .requestLocation:
            return ToolJSONSchema.object(
                properties: [
                    "include_coordinates": ToolJSONSchema.bool(description: "可选。是否在结果里附带经纬度。默认 true。"),
                    "include_address": ToolJSONSchema.bool(description: "可选。是否在结果里附带地址。默认 true。")
                ]
            )
        case .searchNearbyPlaces:
            return ToolJSONSchema.object(
                properties: [
                    "query": ToolJSONSchema.string(description: "必填。附近搜索关键字，例如 景点、餐厅、医院、地铁。"),
                    "radius_meters": ToolJSONSchema.integer(description: "可选。搜索半径，单位米，默认 2000。"),
                    "limit": ToolJSONSchema.integer(description: "可选。最多返回多少个地点。"),
                    "center_query": ToolJSONSchema.string(description: "可选。以某个地点为中心搜索，而不是当前位置。"),
                    "center_name": ToolJSONSchema.string(description: "可选。中心点的人类可读名称。"),
                    "center_latitude": ToolJSONSchema.number(description: "可选。中心点纬度。"),
                    "center_longitude": ToolJSONSchema.number(description: "可选。中心点经度。"),
                    "result_types": ToolJSONSchema.stringArray(description: "可选。结果类型数组，可填 address、point_of_interest、query。"),
                    "include_coordinates": ToolJSONSchema.bool(description: "可选。是否在结果里附带经纬度。默认 false。"),
                    "include_distance_meters": ToolJSONSchema.bool(description: "可选。是否在结果里附带与中心点的距离。默认自动。")
                ],
                required: ["query"]
            )
        case .openMapsRoute:
            return ToolJSONSchema.object(
                properties: [
                    "destination_query": ToolJSONSchema.string(description: "可选。目的地名称或地址。"),
                    "destination_latitude": ToolJSONSchema.number(description: "可选。目的地纬度。"),
                    "destination_longitude": ToolJSONSchema.number(description: "可选。目的地经度。"),
                    "transport_mode": ToolJSONSchema.string(description: "可选。导航方式。", enumValues: ["driving", "walking", "transit"]),
                    "destination_name": ToolJSONSchema.string(description: "可选。给目的地显示的人类可读名称。"),
                    "source_query": ToolJSONSchema.string(description: "可选。出发地名称或地址。默认当前位置。"),
                    "source_latitude": ToolJSONSchema.number(description: "可选。出发地纬度。"),
                    "source_longitude": ToolJSONSchema.number(description: "可选。出发地经度。"),
                    "source_name": ToolJSONSchema.string(description: "可选。给出发地显示的人类可读名称。"),
                    "waypoint_queries": ToolJSONSchema.stringArray(description: "可选。途经点地点名称数组。"),
                    "open_mode": ToolJSONSchema.string(description: "可选。show 表示只打开地点；directions 表示规划路线。默认 directions。", enumValues: ["directions", "show"]),
                    "show_traffic": ToolJSONSchema.bool(description: "可选。是否在地图里显示路况。默认 false。")
                ]
            )
        case .openCamera, .openPhotoLibrary, .scanDocument, .scanLiveText, .requestSpeechPermission, .openAppSettings, .clearSpotlightIndex:
            return ToolJSONSchema.object(properties: [:])
        case .saveGeneratedPhoto:
            return ToolJSONSchema.object(
                properties: [
                    "title": ToolJSONSchema.string(description: "可选。图片标题文本。"),
                    "subtitle": ToolJSONSchema.string(description: "可选。图片副标题文本。"),
                    "body": ToolJSONSchema.string(description: "可选。图片正文文本。"),
                    "width": ToolJSONSchema.integer(description: "可选。图片宽度，默认 1200。"),
                    "height": ToolJSONSchema.integer(description: "可选。图片高度，默认 900。"),
                    "top_color_hex": ToolJSONSchema.string(description: "可选。渐变顶部颜色，格式如 #0EA5E9。"),
                    "middle_color_hex": ToolJSONSchema.string(description: "可选。渐变中间颜色，格式如 #2563EB。"),
                    "bottom_color_hex": ToolJSONSchema.string(description: "可选。渐变底部颜色，格式如 #020617。")
                ]
            )
        case .requestNotificationPermission:
            return ToolJSONSchema.object(
                properties: [
                    "alert": ToolJSONSchema.bool(description: "可选。是否请求 alert 权限，默认 true。"),
                    "badge": ToolJSONSchema.bool(description: "可选。是否请求 badge 权限，默认 true。"),
                    "sound": ToolJSONSchema.bool(description: "可选。是否请求 sound 权限，默认 true。"),
                    "provisional": ToolJSONSchema.bool(description: "可选。是否请求 provisional 权限。默认 false。"),
                    "announcement": ToolJSONSchema.bool(description: "可选。是否请求 Siri announcement 权限。默认 false。"),
                    "carplay": ToolJSONSchema.bool(description: "可选。是否请求 CarPlay 权限。默认 false。"),
                    "critical_alert": ToolJSONSchema.bool(description: "可选。是否请求 critical alert 权限。默认 false。"),
                    "time_sensitive": ToolJSONSchema.bool(description: "可选。是否请求 time sensitive 权限。默认 false。"),
                    "provides_app_notification_settings": ToolJSONSchema.bool(description: "可选。是否声明 app 自带通知设置入口。默认 false。")
                ]
            )
        case .sendLocalNotification:
            return ToolJSONSchema.object(
                properties: [
                    "title": ToolJSONSchema.string(description: "必填。通知标题。"),
                    "subtitle": ToolJSONSchema.string(description: "可选。通知副标题。"),
                    "body": ToolJSONSchema.string(description: "必填。通知正文。"),
                    "delay_seconds": ToolJSONSchema.number(description: "可选。延迟秒数。和 deliver_at 二选一。"),
                    "deliver_at": ToolJSONSchema.string(description: "可选。指定绝对投递时间，ISO8601。和 delay_seconds 二选一。", format: "date-time"),
                    "repeats": ToolJSONSchema.bool(description: "可选。是否重复触发。默认 false。"),
                    "identifier": ToolJSONSchema.string(description: "可选。通知唯一标识。"),
                    "thread_id": ToolJSONSchema.string(description: "可选。通知线程 ID。"),
                    "category_id": ToolJSONSchema.string(description: "可选。通知 category identifier。"),
                    "badge": ToolJSONSchema.integer(description: "可选。应用角标。"),
                    "user_info": ToolJSONSchema.dictionary(description: "可选。附带到通知的 userInfo。"),
                    "interruption_level": ToolJSONSchema.string(description: "可选。打断级别。", enumValues: ["active", "passive", "time_sensitive", "critical"]),
                    "sound_name": ToolJSONSchema.string(description: "可选。自定义声音文件名。")
                ],
                required: ["title", "body"]
            )
        case .speakText:
            return ToolJSONSchema.object(
                properties: [
                    "operation": ToolJSONSchema.string(description: "可选。默认 speak。也可 pause、stop、continue。", enumValues: ["speak", "pause", "stop", "continue"]),
                    "text": ToolJSONSchema.string(description: "operation=speak 时必填。要朗读的文本。"),
                    "language": ToolJSONSchema.string(description: "可选。语音语言，例如 zh-CN、en-US。"),
                    "rate": ToolJSONSchema.number(description: "可选。朗读速度，建议 0.1 到 0.6。"),
                    "pitch": ToolJSONSchema.number(description: "可选。音高，建议 0.5 到 2.0。"),
                    "volume": ToolJSONSchema.number(description: "可选。音量，范围 0 到 1。"),
                    "pre_utterance_delay": ToolJSONSchema.number(description: "可选。朗读前延迟秒数。"),
                    "post_utterance_delay": ToolJSONSchema.number(description: "可选。朗读后延迟秒数。"),
                    "voice_identifier": ToolJSONSchema.string(description: "可选。指定系统 voice identifier。"),
                    "queue_behavior": ToolJSONSchema.string(description: "可选。speak 时的队列行为。", enumValues: ["append", "interrupt", "pause"]),
                    "boundary": ToolJSONSchema.string(description: "可选。pause/stop 的边界。", enumValues: ["immediate", "word"])
                ]
            )
        case .openMailDraft:
            return ToolJSONSchema.object(
                properties: [
                    "mailto_url": ToolJSONSchema.string(description: "可选。直接打开完整 mailto URL。", format: "uri"),
                    "to": ToolJSONSchema.stringArray(description: "可选。收件人邮箱数组。"),
                    "cc": ToolJSONSchema.stringArray(description: "可选。抄送邮箱数组。"),
                    "bcc": ToolJSONSchema.stringArray(description: "可选。密送邮箱数组。"),
                    "subject": ToolJSONSchema.string(description: "可选。邮件主题。"),
                    "body": ToolJSONSchema.string(description: "可选。邮件正文。")
                ]
            )
        case .openMessageDraft:
            return ToolJSONSchema.object(
                properties: [
                    "sms_url": ToolJSONSchema.string(description: "可选。直接打开完整 sms URL。", format: "uri"),
                    "recipients": ToolJSONSchema.stringArray(description: "可选。短信接收人号码数组。"),
                    "body": ToolJSONSchema.string(description: "可选。短信正文。")
                ]
            )
        case .callPhoneNumber:
            return ToolJSONSchema.object(
                properties: [
                    "number": ToolJSONSchema.string(description: "必填。要拨打的电话号码。")
                ],
                required: ["number"]
            )
        case .openFaceTime:
            return ToolJSONSchema.object(
                properties: [
                    "target": ToolJSONSchema.string(description: "必填。FaceTime 目标，可以是手机号、邮箱或 FaceTime 链接。"),
                    "call_type": ToolJSONSchema.string(description: "可选。audio 表示 FaceTime Audio；video 表示视频。默认 video。", enumValues: ["audio", "video"])
                ],
                required: ["target"]
            )
        case .openAppStore:
            return ToolJSONSchema.object(
                properties: [
                    "url": ToolJSONSchema.string(description: "可选。直接打开的 App Store URL。", format: "uri"),
                    "search_term": ToolJSONSchema.string(description: "可选。App Store 搜索词。"),
                    "app_id": ToolJSONSchema.string(description: "可选。指定 App 的数字 ID。"),
                    "country_code": ToolJSONSchema.string(description: "可选。国家/地区代码，默认 cn。")
                ]
            )
        case .openPodcasts, .openBooks, .openTV:
            return ToolJSONSchema.object(
                properties: [
                    "url": ToolJSONSchema.string(description: "可选。直接打开的完整 URL。", format: "uri"),
                    "search_term": ToolJSONSchema.string(description: "可选。搜索关键字。"),
                    "country_code": ToolJSONSchema.string(description: "可选。国家/地区代码，默认 cn。")
                ]
            )
        case .indexWorkspaceToSpotlight:
            return ToolJSONSchema.object(
                properties: [
                    "path": ToolJSONSchema.string(description: "可选。要建立索引的相对路径，默认整个工作区。"),
                    "recursive": ToolJSONSchema.bool(description: "可选。是否递归索引目录，默认 true。")
                ]
            )
        case .appIntentsDiagnostics:
            return ToolJSONSchema.object(
                properties: [
                    "include_phrases": ToolJSONSchema.bool(description: "可选。是否输出快捷短语。默认 true。")
                ]
            )
        case .publishHandoffActivity:
            return ToolJSONSchema.object(
                properties: [
                    "activity_type": ToolJSONSchema.string(description: "可选。NSUserActivity 的 activityType。"),
                    "title": ToolJSONSchema.string(description: "可选。活动标题。"),
                    "screen": ToolJSONSchema.string(description: "可选。当前 screen 标识。"),
                    "user_info": ToolJSONSchema.dictionary(description: "可选。附加到 NSUserActivity 的 userInfo。")
                ]
            )
        }
    }
}
