import SwiftUI

struct ContentView: View {
    @Bindable var store: ManualLabStore
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var skillRegistry: SkillRegistry
    @State private var chatStore: ChatStore

    init(
        manualLabStore: ManualLabStore,
        workspaceStore: WorkspaceStore,
        skillRegistry: SkillRegistry,
        chatStore: ChatStore
    ) {
        self._store = Bindable(wrappedValue: manualLabStore)
        self._workspaceStore = Bindable(wrappedValue: workspaceStore)
        self._skillRegistry = Bindable(wrappedValue: skillRegistry)
        self._chatStore = State(initialValue: chatStore)
    }

    var body: some View {
        WorkspaceShellScreen(
            workspaceStore: workspaceStore,
            manualLabStore: store,
            skillRegistry: skillRegistry,
            chatStore: chatStore
        )
    }
}

#Preview {
    let container = AppContainer()
    ContentView(
        manualLabStore: container.store,
        workspaceStore: container.workspaceStore,
        skillRegistry: container.skillRegistry,
        chatStore: container.chatStore
    )
}
