import SwiftUI
struct ImageGenerationConfigurationScreen: View {
    @Bindable var library: ModelLibraryStore
    @State private var settings = ImageGenerationConfigurationStore.shared
    @State private var account = ChatGPTAccountStore.shared
    private var models: [ModelRecord] {
        library.state.models.filter { model in
            model.imageGenerationOnly && account.account != nil
                && library.state.connection(model.connectionID)?.chatGPTAccount?.accountID == account.account?.accountID
        }
    }
    var body: some View {
        List {
            Section {
                Picker(PalmiL10n.tr("image.model"), selection: $settings.selectedModelID) {
                    Text(PalmiL10n.tr("common.none")).tag(Optional<UUID>.none)
                    ForEach(models) { model in Label(model.title, systemImage: "photo").tag(Optional(model.id)) }
                    if let id = settings.selectedModelID, !models.contains(where: { $0.id == id }) {
                        Text(PalmiL10n.tr("image.unavailableModel")).tag(Optional(id))
                    }
                }
                .pickerStyle(.menu)
                .tint(models.isEmpty ? Color.secondary : Color.accentColor)
                if let active = account.account { LabeledContent("Codex OAuth", value: active.email.isEmpty ? active.accountID : active.email) }
                NavigationLink { ChatGPTOAuthScreen(library: library) }
                label: {
                    Label {
                        Text("Codex OAuth")
                    } icon: {
                        Image("CodexOAuthLogo").renderingMode(.template).resizable()
                            .scaledToFit().frame(width: 18, height: 18)
                    }
                }
            }
        }
        .navigationTitle(PalmiL10n.tr("image.configuration")).navigationBarTitleDisplayMode(.inline)
    }
}
