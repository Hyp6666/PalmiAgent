import SwiftUI

struct ContentView: View {
    @Bindable var store: ManualLabStore
    @Bindable var workspaceStore: WorkspaceStore
    @Bindable var skillRegistry: SkillRegistry
    @State private var chatStore: ChatStore
    @State private var bionicStore: BionicStore

    init(manualLabStore: ManualLabStore, workspaceStore: WorkspaceStore,
         skillRegistry: SkillRegistry, chatStore: ChatStore, bionicStore: BionicStore) {
        self._store = Bindable(wrappedValue: manualLabStore)
        self._workspaceStore = Bindable(wrappedValue: workspaceStore)
        self._skillRegistry = Bindable(wrappedValue: skillRegistry)
        self._chatStore = State(initialValue: chatStore)
        self._bionicStore = State(initialValue: bionicStore)
    }
    var body: some View {
        WorkspaceShellScreen(workspaceStore: workspaceStore, manualLabStore: store,
                             skillRegistry: skillRegistry, chatStore: chatStore, bionicStore: bionicStore)
    }
}

#Preview {
    let container = AppContainer()
    ContentView(manualLabStore: container.store, workspaceStore: container.workspaceStore,
                skillRegistry: container.skillRegistry, chatStore: container.chatStore,
                bionicStore: container.bionicStore)
}
