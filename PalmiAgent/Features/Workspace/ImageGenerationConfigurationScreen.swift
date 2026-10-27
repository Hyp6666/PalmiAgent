import SwiftUI

/// 图片生成：从 Codex OAuth 账号的生图模型里选一个；未登录时给出登录入口。
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
                choice(PalmiL10n.tr("common.none"), selected: settings.selectedModelID == nil) { settings.selectedModelID = nil }
                ForEach(models) { model in
                    choice(model.title, selected: settings.selectedModelID == model.id) { settings.selectedModelID = model.id }
                }
            }
            if account.account == nil {
                Section {
                    NavigationLink { ChatGPTOAuthScreen(library: library) } label: {
                        Text("Codex OAuth")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("image.generation"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
