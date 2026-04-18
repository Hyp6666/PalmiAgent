import AppIntents

struct OpenPalmiAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 PalmiAgent 开发者模式"
    static let description = IntentDescription("打开 PalmiAgent 的开发者模式。")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result(dialog: "PalmiAgent 已经打开。")
    }
}

struct CreateWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "创建 Palmi 工作区"
    static let description = IntentDescription("在 PalmiAgent 内创建测试工作区，并写入一份 README。")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            let manager = WorkspaceManager()
            _ = try manager.ensureWorkspace()
            _ = try manager.writeReadme()
        }
        return .result(dialog: "工作区已经创建并写入 README。")
    }
}

struct PalmiAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenPalmiAgentIntent(),
            phrases: [
                "打开 \(.applicationName)",
                "启动 \(.applicationName) 开发者模式"
            ],
            shortTitle: "开发者模式",
            systemImageName: "sparkles.rectangle.stack"
        )
        AppShortcut(
            intent: CreateWorkspaceIntent(),
            phrases: [
                "用 \(.applicationName) 创建工作区",
                "让 \(.applicationName) 新建测试目录"
            ],
            shortTitle: "创建工作区",
            systemImageName: "folder.badge.plus"
        )
    }
}
