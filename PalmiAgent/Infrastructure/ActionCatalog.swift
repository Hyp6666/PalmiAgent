import Foundation

enum ActionCatalog {
    static let all: [ToolAction] = [
        .init(id: .bootstrapWorkspace, category: .workspace, title: "初始化工作区", effect: "确保当前项目或聊天的工作区已就绪", details: "如果当前工作区还不存在就创建；如果已经存在则直接复用。", availability: .live),
        .init(id: .writeFile, category: .workspace, title: "写入文件", effect: "写入任意文本文件到工作区", details: "由模型提供文件路径和内容，支持 .md、.py、.js、.txt、.json 等所有文本格式。根据文件扩展名自动推断用途。", availability: .live),
        .init(id: .read, category: .workspace, title: "read", effect: "读取文件或目录里的可读文本", details: "支持代码、Markdown、JSON、CSV、PDF、RTF、plist、ipynb 等文本内容；图片和其他二进制会自动忽略。适合定位本地来源，也适合显式精读长文档；支持用 mode / focus / offset / chunk_size 控制读取范围。", availability: .live),
        .init(id: .listWorkspaceFiles, category: .workspace, title: "列出工作区文件", effect: "列出当前工作区内所有文件", details: "用于快速验证文件落盘和后续导出。", availability: .live),
        .init(id: .inspectSandboxCapabilities, category: .workspace, title: "查看沙盒能力边界", effect: "输出当前 iOS 沙盒运行时的真实上限", details: "明确哪些是可做的模拟终端，哪些是真实 shell 目前做不到。", availability: .live),
        .init(id: .runSandboxTerminal, category: .workspace, title: "运行终端脚本", effect: "执行一段受控终端脚本并生成 transcript", details: "支持多行脚本，适合单轮真实工具调用。", availability: .live),
        .init(id: .exportWorkspace, category: .workspace, title: "导出工作区", effect: "弹出系统分享面板", details: "把整个工作区目录作为文件 URL 导出。", availability: .live),
        .init(id: .runJavaScriptSandbox, category: .workspace, title: "运行脚本沙盒", effect: "用 JavaScriptCore 执行工作区里的脚本", details: "这版已经接入 workspace API，可读写文件并输出执行日志。", availability: .live),
        .init(id: .pythonSandbox, category: .workspace, title: "Python 沙盒", effect: "执行真实 CPython 脚本并返回结果", details: "使用内嵌 CPython 3.14 运行工作区里的 Python 代码。适合数学计算、符号推导、图算法、JSON/CSV/Excel 处理和文件读写；支持常见标准库、内置 workspace 辅助模块，以及预装纯 Python 包：\(PythonPackageCatalog.supportedImportsSentence)。\(PythonPackageCatalog.toolingSummary) 不支持 pip 即装即用、系统进程、GUI、长期阻塞脚本，以及任何未列出的第三方库（例如 \(PythonPackageCatalog.unsupportedExamplesSentence)）。", availability: .live),
        .init(id: .searchWeb, category: .web, title: "网页搜索", effect: "按关键词搜索网页并返回候选 URL", details: "当前通过原生 WebKit 无感加载百度搜索结果页并提取链接。它负责找候选来源；需要精读时，应继续调用网页浏览或批量抓取工具。", availability: .live),
        .init(id: .fetchStaticWebPage, category: .web, title: "网页浏览", effect: "按 URL 读取网页标题与正文片段", details: "适合已知网址的单页读取，不负责搜索。", availability: .live),
        .init(id: .fetchWebBatch, category: .web, title: "批量抓取网页", effect: "并发抓取多个网页", details: "由模型传入 URL 数组并并发执行抓取，返回标题、URL、字节数和正文片段。", availability: .live),
        .init(id: .saveWebPageToWorkspace, category: .web, title: "网页结果落盘", effect: "把抓取结果保存到工作区", details: "便于后续 Agent 再加工和导出。", availability: .live),
        .init(id: .openInAppBrowser, category: .web, title: "打开内置浏览器", effect: "在 app 内打开网页预览", details: "当前用 Safari View 验证链路。", availability: .partial),
        .init(id: .createCalendarEvent, category: .personalData, title: "创建日历事件", effect: "写入一条日历事件", details: "支持标题、备注、开始时间和结束时间。", availability: .live),
        .init(id: .listTodayEvents, category: .personalData, title: "查看今日日历", effect: "读取今天的日历事件", details: "验证 EventKit 事件读取能力。", availability: .live),
        .init(id: .createReminder, category: .personalData, title: "创建提醒事项", effect: "写入一条提醒事项", details: "支持标题、备注和截止时间。", availability: .live),
        .init(id: .listReminders, category: .personalData, title: "查看未完成提醒", effect: "读取未完成提醒", details: "验证提醒事项读取能力。", availability: .live),
        .init(id: .createContact, category: .personalData, title: "创建联系人", effect: "写入一个联系人", details: "支持姓名、组织、电话、邮箱和备注。", availability: .live),
        .init(id: .searchContacts, category: .personalData, title: "搜索联系人", effect: "按关键字搜索联系人", details: "验证通讯录读取能力。", availability: .live),
        .init(id: .getCurrentDateTime, category: .personalData, title: "获取当前时间", effect: "读取设备当前本地日期时间", details: "返回当前本地时间、时区、今天和明天，用来避免相对日期和年份幻觉。", availability: .live),
        .init(id: .requestAlarmPermission, category: .personalData, title: "请求闹钟权限", effect: "请求系统闹钟权限", details: "通过 AlarmKit 请求系统闹钟授权。", availability: .live),
        .init(id: .listAlarms, category: .personalData, title: "查看系统闹钟", effect: "读取当前系统闹钟和计时器", details: "返回闹钟 ID、状态和调度方式。", availability: .live),
        .init(id: .createAlarm, category: .personalData, title: "创建系统闹钟", effect: "创建系统时钟闹钟", details: "支持固定时间闹钟、按时分重复的闹钟，以及自定义 app 内闹钟声音名。", availability: .live),
        .init(id: .createClockTimer, category: .personalData, title: "创建系统倒计时", effect: "创建系统时钟倒计时", details: "支持指定倒计时秒数和 app 内闹钟声音名。", availability: .live),
        .init(id: .manageAlarm, category: .personalData, title: "管理系统闹钟", effect: "暂停、继续、停止或取消系统闹钟", details: "通过 AlarmKit 按闹钟 ID 管理当前闹钟。", availability: .live),
        .init(id: .requestLocation, category: .personalData, title: "请求定位并反查", effect: "获取当前位置并反向地理编码", details: "验证定位和地址解析能力。", availability: .live),
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
}
