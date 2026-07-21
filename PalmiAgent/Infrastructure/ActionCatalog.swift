import Foundation

enum ActionCatalog {
    static let agentExposedActionIDs: [ToolActionID] = [
        .fileRead,
        .fileWrite,
        .fileAppend,
        .listDirectory,
        .fileManage,
        .runPython,
        .recognizeImageText,
        .scanImageWithMultimodalModel,
        .searchWeb,
        .fetchStaticWebPage,
        .getCurrentDateTime,
        .requestLocation
    ]

    static let all: [ToolAction] = [
        .init(id: .fileRead, category: .workspace, title: "读取文件", effect: "读取工作区内单个文件的文本内容", details: "支持代码、Markdown、JSON、CSV、PDF、RTF、plist、ipynb 等文本内容；图片和其他二进制会自动忽略。支持用 mode / focus / offset / chunk_size 控制读取范围，适合精读长文档。", availability: .live),
        .init(id: .fileWrite, category: .workspace, title: "写入文件", effect: "创建或覆盖写入工作区内的文本文件", details: "由模型提供文件路径和内容，支持 .md、.py、.txt、.json 等所有文本格式。父目录会自动创建。", availability: .live),
        .init(id: .fileAppend, category: .workspace, title: "追加内容", effect: "向工作区内已有文件末尾追加文本", details: "文件不存在时自动创建。适合日志追加、分步写入等场景。", availability: .live),
        .init(id: .listDirectory, category: .workspace, title: "列出目录", effect: "列出工作区目录的内容或递归目录树", details: "可查看指定目录下的文件和子目录，支持递归输出完整目录树。还可批量读取目录内所有可读文本文件的内容。", availability: .live),
        .init(id: .fileManage, category: .workspace, title: "文件管理", effect: "移动、复制、重命名、删除文件或创建目录", details: "通过 operation 参数选择操作：mkdir（创建目录）、delete（删除）、move（移动/重命名）、copy（复制）、info（查看文件信息）、exists（检查是否存在）。覆盖人手工能做的所有文件管理操作。", availability: .live),
        .init(id: .runPython, category: .workspace, title: "执行 Python", effect: "执行真实 CPython 脚本并返回结果", details: "使用内嵌 CPython 3.14 运行 Python 代码。适合数学计算、符号推导、图算法、JSON/CSV/Excel 处理；支持标准库、内置 workspace 辅助模块，以及预装纯 Python 包：\(PythonPackageCatalog.supportedImportsSentence)。\(PythonPackageCatalog.toolingSummary) 不支持 pip 即装即用、系统进程、GUI、长期阻塞脚本，以及任何未列出的第三方库（例如 \(PythonPackageCatalog.unsupportedExamplesSentence)）。文件操作请优先使用专用文件工具（读取文件、写入文件、文件管理等），不要用 Python 绕路。", availability: .live),
        .init(id: .recognizeImageText, category: .multimodal, title: "OCR 扫描", effect: "识别工作区图片里的文字并写出 OCR 文本与 JSON", details: "使用随包集成的 PP-OCRv6 Tiny det/rec 模型资源作为本地 OCR 能力入口。传入工作区图片相对路径后，会把纯文本写入 .ocr.txt，把行级文本、置信度、位置和模型信息写入 .ocr.json；附件图片默认输出到同批次 extracted 目录，其他图片默认输出到 .files/ocr。", availability: .live),
        .init(id: .scanImageWithMultimodalModel, category: .multimodal, title: "多模态模型扫描", effect: "调用当前配置的多模态模型理解工作区图片并返回文本结果", details: "传入工作区图片相对路径和提示词后，Palmi 会把图片内联给当前会话配置的多模态模型。若当前会话没有可用多模态模型，工具调用会直接返回失败。", availability: .live),
        .init(id: .detectWebSearchProviders, category: .web, title: "网络环境检测", effect: "探测当前已开启搜索源的可访问性", details: "按设置中开启的搜索源发起轻量网络探测，返回每个搜索源是否可访问、响应耗时和 HTTP 状态。它只做环境检测，不读取搜索结果。", availability: .live),
        .init(id: .searchWeb, category: .web, title: "网页搜索", effect: "按关键词搜索网页并返回候选 URL", details: "使用当前启用的搜索源在本地 WebKit 中读取真实搜索结果 DOM，返回标题、规范化 URL 和摘要，不读取正文。需要证据时继续调用网页浏览。", availability: .live),
        .init(id: .fetchStaticWebPage, category: .web, title: "网页浏览", effect: "按一个或多个 URL 读取完整网页文字或归档网页素材", details: "page_text 返回整个页面的可见文字，不自行筛选正文，并支持 start/end 字符区间。full_snapshot 会把页面和实际引用的图片、CSS、脚本、字体等素材保存为独立文件夹，网络、时间和存储开销较高；只有普通读取失败且换过更合适来源后仍无效时才能使用。支持 HTML、JavaScript 页面、PDF、纯文本、JSON 与 XML，单次最多 10 个 URL。", availability: .live),
        .init(id: .openInAppBrowser, category: .web, title: "打开内置浏览器", effect: "在 app 内打开网页预览", details: "支持 http/https 网页，也支持工作区内 HTML 文件预览。生成交互式网页、小游戏或可视化作品时，除非用户或技能另有指定，推荐将入口放在 artifacts/<短名称>/index.html，资源放同目录子目录。", availability: .partial),
        .init(id: .createCalendarEvent, category: .personalData, title: "创建日历事件", effect: "写入一条日历事件", details: "支持标题、备注、开始时间和结束时间。", availability: .live),
        .init(id: .listTodayEvents, category: .personalData, title: "查看今日日历", effect: "读取今天的日历事件", details: "验证 EventKit 事件读取能力。", availability: .live),
        .init(id: .createReminder, category: .personalData, title: "创建提醒事项", effect: "写入一条提醒事项", details: "支持标题、备注和截止时间。", availability: .live),
        .init(id: .listReminders, category: .personalData, title: "查看未完成提醒", effect: "读取未完成提醒", details: "验证提醒事项读取能力。", availability: .live),
        .init(id: .createContact, category: .personalData, title: "创建联系人", effect: "写入一个联系人", details: "支持姓名、组织、电话、邮箱和备注。", availability: .live),
        .init(id: .searchContacts, category: .personalData, title: "搜索联系人", effect: "按关键字搜索联系人", details: "验证通讯录读取能力。", availability: .live),
        .init(id: .getCurrentDateTime, category: .personalData, title: "获取时间", effect: "读取设备当前本地日期时间", details: "返回当前本地时间、时区、今天和明天，用来避免相对日期和年份幻觉。", availability: .live),
        .init(id: .requestAlarmPermission, category: .personalData, title: "请求闹钟权限", effect: "请求系统闹钟权限", details: "通过 AlarmKit 请求系统闹钟授权。", availability: .live),
        .init(id: .listAlarms, category: .personalData, title: "查看系统闹钟", effect: "读取当前系统闹钟和计时器", details: "返回闹钟 ID、状态和调度方式。", availability: .live),
        .init(id: .createAlarm, category: .personalData, title: "创建系统闹钟", effect: "创建系统时钟闹钟", details: "支持固定时间闹钟、按时分重复的闹钟，以及自定义 app 内闹钟声音名。", availability: .live),
        .init(id: .createClockTimer, category: .personalData, title: "创建系统倒计时", effect: "创建系统时钟倒计时", details: "支持指定倒计时秒数和 app 内闹钟声音名。", availability: .live),
        .init(id: .manageAlarm, category: .personalData, title: "管理系统闹钟", effect: "暂停、继续、停止或取消系统闹钟", details: "通过 AlarmKit 按闹钟 ID 管理当前闹钟。", availability: .live),
        .init(id: .requestLocation, category: .personalData, title: "获取定位", effect: "获取当前位置并反向地理编码", details: "验证定位和地址解析能力。", availability: .live),
        .init(id: .searchNearbyPlaces, category: .personalData, title: "搜索附近地点", effect: "按关键字搜索附近地点", details: "适合景点、餐厅、商场、医院、地铁站等 POI 搜索。", availability: .live),
        .init(id: .openMapsRoute, category: .personalData, title: "打开地图路线", effect: "跳转 Apple 地图规划路线", details: "验证系统地图 handoff。", availability: .live),
        .init(id: .openCamera, category: .media, title: "打开相机", effect: "弹出系统相机", details: "拉起系统相机供用户继续拍摄。", availability: .live),
        .init(id: .openPhotoLibrary, category: .media, title: "打开相册", effect: "弹出系统相册选择器", details: "验证图片选择链路。", availability: .live),
        .init(id: .saveGeneratedPhoto, category: .media, title: "生成并保存图片", effect: "生成一张图片并保存到照片", details: "支持自定义文本、尺寸和渐变颜色。", availability: .live),
        .init(id: .scanDocument, category: .media, title: "扫描文档", effect: "弹出文档扫描器", details: "验证 VisionKit 文档扫描能力。", availability: .live),
        .init(id: .scanLiveText, category: .media, title: "实时文本扫描", effect: "打开实时文本扫描器", details: "验证 Live Text 识别链路。", availability: .live),
        .init(id: .requestNotificationPermission, category: .media, title: "请求通知权限", effect: "申请本地通知授权", details: "验证通知授权状态。", availability: .live),
        .init(id: .sendLocalNotification, category: .media, title: "发送本地通知", effect: "按指定延迟发送本地通知", details: "支持自定义标题、正文和延迟秒数。", availability: .live),
        .init(id: .requestSpeechPermission, category: .media, title: "请求语音权限", effect: "申请语音识别与麦克风权限", details: "验证 Speech 权限链路。", availability: .live),
        .init(id: .speakText, category: .media, title: "朗读文本", effect: "用 TTS 朗读一段文本", details: "支持自定义文本、语言和语速。", availability: .live),
        .init(id: .openMailDraft, category: .communication, title: "打开邮件草稿", effect: "跳转系统邮件草稿", details: "当前走系统 handoff，不读邮件收件箱。", availability: .live),
        .init(id: .openMessageDraft, category: .communication, title: "打开短信草稿", effect: "跳转系统短信草稿", details: "当前不支持静默发短信。", availability: .live),
        .init(id: .callPhoneNumber, category: .communication, title: "拨打号码", effect: "调起系统电话", details: "支持传入任意电话号码。", availability: .live),
        .init(id: .openFaceTime, category: .communication, title: "打开 FaceTime", effect: "调起 FaceTime", details: "当前只是验证系统跳转链路。", availability: .live),
        .init(id: .openAppSettings, category: .communication, title: "打开本应用设置", effect: "跳转系统设置中的本应用页", details: "不直接改系统设置，只把用户送过去。", availability: .live),
        .init(id: .openAppStore, category: .communication, title: "打开 App Store", effect: "打开 App Store 搜索页", details: "验证苹果内容入口 handoff。", availability: .live),
        .init(id: .openPodcasts, category: .communication, title: "打开播客", effect: "打开播客入口", details: "当前只做跳转，不做个人库管理。", availability: .live),
        .init(id: .openBooks, category: .communication, title: "打开图书", effect: "打开图书入口", details: "当前只做跳转。", availability: .live),
        .init(id: .openTV, category: .communication, title: "打开视频", effect: "打开 Apple TV 入口", details: "当前只做跳转。", availability: .live),
        .init(id: .indexWorkspaceToSpotlight, category: .intelligence, title: "索引工作区到 Spotlight", effect: "把文件加入系统搜索", details: "验证系统索引链路。", availability: .live),
        .init(id: .clearSpotlightIndex, category: .intelligence, title: "清空 Spotlight 索引", effect: "删除工作区索引", details: "移除当前工作区建立的 Spotlight 搜索索引。", availability: .live),
        .init(id: .appIntentsDiagnostics, category: .intelligence, title: "检查 App Intents", effect: "显示已编译进来的快捷指令入口", details: "这一版 App Intents 直接放主 app target。", availability: .live),
        .init(id: .publishHandoffActivity, category: .intelligence, title: "发布继续活动", effect: "把当前状态变成可继续活动", details: "验证 Handoff / NSUserActivity 链路。", availability: .live)
    ]

    static func grouped() -> [(category: ToolCategory, actions: [ToolAction])] {
        ToolCategory.allCases.compactMap { category in
            let actions = all.filter { $0.category == category }
            return actions.isEmpty ? nil : (category, actions)
        }
    }

    static func agentExposedActions(from actions: [ToolAction]) -> [ToolAction] {
        let actionsByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        return agentExposedActionIDs.compactMap { actionsByID[$0] }
    }
}
