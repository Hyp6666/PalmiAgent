import SwiftUI
import UIKit

@main
struct PalmiAgentApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var container = AppContainer()
    @AppStorage(PalmiLanguage.storageKey) private var languageID = PalmiLanguage.zhHans.rawValue

    init() {
        PalmiReasoningUIStyle.migrateDefaultIfNeeded()
        AppShellModeSegmentedPicker.configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(manualLabStore: container.store, workspaceStore: container.workspaceStore,
                        skillRegistry: container.skillRegistry, chatStore: container.chatStore,
                        bionicStore: container.bionicStore)
            .environment(container.browserOperatorService)
            .environment(container.userQuestionService)
            .environment(\.locale, PalmiLanguage.resolve(languageID).locale)
            .environment(\.layoutDirection, PalmiLanguage.resolve(languageID).isRightToLeft ? .rightToLeft : .leftToRight)
            .task {
                await container.bionicStore.purchases.start()
                await container.bionicStore.bootstrap()
                if scenePhase == .background { container.bionicStore.pause() }
                else if scenePhase == .inactive { container.bionicStore.sceneBecameInactive() }
            }
            .onChange(of: scenePhase) { _, newPhase in handleScenePhaseChange(newPhase) }

        }
    }
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // 吸收旧版本在后台期间的配置修改；钥匙串锁定导致的迁移推迟也在此重试。
            container.modelLibraryStore.reconcileAllSources()
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
