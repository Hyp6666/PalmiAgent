import SwiftUI

@main
struct PalmiAgentApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ContentView(
                manualLabStore: container.store,
                workspaceStore: container.workspaceStore,
                skillRegistry: container.skillRegistry,
                chatStore: container.chatStore
            )
        }
    }
}
