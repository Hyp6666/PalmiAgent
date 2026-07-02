import AppIntents

struct OpenPalmiAgentIntent: AppIntent {
    static let title = LocalizedStringResource("intent.openDeveloper.title", table: "Localizable")
    static let description = IntentDescription(LocalizedStringResource("intent.openDeveloper.description", table: "Localizable"))
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result(dialog: IntentDialog(LocalizedStringResource("intent.openDeveloper.dialog", table: "Localizable")))
    }
}

struct CreateWorkspaceIntent: AppIntent {
    static let title = LocalizedStringResource("intent.createWorkspace.title", table: "Localizable")
    static let description = IntentDescription(LocalizedStringResource("intent.createWorkspace.description", table: "Localizable"))
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            let manager = WorkspaceManager()
            _ = try manager.ensureWorkspace()
            _ = try manager.writeReadme()
        }
        return .result(dialog: IntentDialog(LocalizedStringResource("intent.createWorkspace.dialog", table: "Localizable")))
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
            shortTitle: LocalizedStringResource("intent.openDeveloper.shortTitle", table: "Localizable"),
            systemImageName: "sparkles.rectangle.stack"
        )
        AppShortcut(
            intent: CreateWorkspaceIntent(),
            phrases: [
                "Create a workspace with \(.applicationName)",
                "Make a test workspace in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("intent.createWorkspace.shortTitle", table: "Localizable"),
            systemImageName: "folder.badge.plus"
        )
    }
}
