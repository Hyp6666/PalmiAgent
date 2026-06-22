import SwiftUI
import UIKit

@main
struct PalmiAgentApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ContentView(
                manualLabStore: container.store,
                workspaceStore: container.workspaceStore,
                skillRegistry: container.skillRegistry,
                chatStore: container.chatStore
            )
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
#if DEBUG
            .task {
                MultimodalRoutingSelfTest.runIfRequested()
            }
#endif
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .inactive || phase == .background else { return }

        let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PalmiAgentSessionFlush")
        container.chatStore.flushForAppBackground()
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
        }
    }
}
