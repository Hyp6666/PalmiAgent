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
                await container.bionicStore.purchases.start()
                await container.bionicStore.bootstrap()
                if scenePhase == .background { container.bionicStore.pause() }
                else if scenePhase == .inactive { container.bionicStore.sceneBecameInactive() }
            }
            .onChange(of: scenePhase) { _, newPhase in handleScenePhaseChange(newPhase) }
            .onChange(of: container.bionicStore.purchases.canUse) { _, enabled in
                guard enabled, scenePhase == .active else { return }
                Task { await container.bionicStore.coordinator.activate() }
            }
        }
    }
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task {
                await container.bionicStore.activate()
                await container.bionicStore.purchases.refreshEntitlements()
            }
        case .inactive:
            container.bionicStore.sceneBecameInactive()
        case .background:
            container.bionicStore.pause()
            let backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PalmiAgentSessionFlush")
            container.chatStore.flushForAppBackground()
            if backgroundTaskID != .invalid { UIApplication.shared.endBackgroundTask(backgroundTaskID) }
        @unknown default:
            container.bionicStore.sceneBecameInactive()
        }
    }
}
