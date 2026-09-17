import SwiftUI
import UIKit

@main
struct PalmiAgentApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ContentView(manualLabStore: container.store, workspaceStore: container.workspaceStore,
                        skillRegistry: container.skillRegistry, chatStore: container.chatStore,
                        bionicStore: container.bionicStore)
            .task {
                await container.bionicStore.bootstrap()
                if scenePhase != .active { container.bionicStore.pause() }
            }
            .onChange(of: scenePhase) { _, newPhase in handleScenePhaseChange(newPhase) }
        }
    }
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await container.bionicStore.activate() }
        case .inactive, .background:
            container.bionicStore.pause()
            let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PalmiAgentSessionFlush")
            container.chatStore.flushForAppBackground()
            if backgroundTaskID != .invalid { UIApplication.shared.endBackgroundTask(backgroundTaskID) }
        @unknown default:
            container.bionicStore.pause()
        }
    }
}
