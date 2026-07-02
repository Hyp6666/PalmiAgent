import AppIntents

struct OpenPalmiAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.openDeveloper.title"
    static let description = IntentDescription("intent.openDeveloper.description")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result(dialog: "intent.openDeveloper.dialog")
    }
}

struct CreateWorkspaceIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.createWorkspace.title"
    static let description = IntentDescription("intent.createWorkspace.description")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            let manager = WorkspaceManager()
            _ = try manager.ensureWorkspace()
            _ = try manager.writeReadme()
        }
        return .result(dialog: "intent.createWorkspace.dialog")
    }
}

struct PalmiAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenPalmiAgentIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Launch \(.applicationName) developer mode"
            ],
            shortTitle: "intent.openDeveloper.shortTitle",
            systemImageName: "sparkles.rectangle.stack"
        )
        AppShortcut(
            intent: CreateWorkspaceIntent(),
            phrases: [
                "Create a workspace with \(.applicationName)",
                "Make a test workspace in \(.applicationName)"
            ],
            shortTitle: "intent.createWorkspace.shortTitle",
            systemImageName: "folder.badge.plus"
        )
    }
}
