import SwiftUI

private enum SearchConfigurationMode: Hashable {
    case local
    case remote
}

struct SearchConfigurationScreen: View {
    @Bindable var remoteSearchStore: RemoteSearchConfigurationStore
    @Bindable var permissionStore: ToolPermissionStore
    let remoteWebSearchService: RemoteWebSearchService
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section(PalmiL10n.tr("searchConfiguration.currentMode")) {
                Picker(
                    PalmiL10n.tr("searchConfiguration.currentMode"),
                    selection: Binding(
                        get: {
                            remoteSearchStore.activeConfigurationID() == nil
                                ? .local
                                : .remote
                        },
                        set: activate
                    )
                ) {
                    Text(PalmiL10n.tr("searchConfiguration.mode.local"))
                        .tag(SearchConfigurationMode.local)
                    Text(PalmiL10n.tr("searchConfiguration.mode.remote"))
                        .tag(SearchConfigurationMode.remote)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section(PalmiL10n.tr("searchConfiguration.section")) {
                NavigationLink {
                    WebSearchProviderSettingsScreen()
                } label: {
                    Label(
                        PalmiL10n.tr("searchConfiguration.local.title"),
                        systemImage: "magnifyingglass.circle"
                    )
                }

                NavigationLink {
                    RemoteSearchConfigurationScreen(
                        store: remoteSearchStore,
                        permissionStore: permissionStore,
                        remoteWebSearchService: remoteWebSearchService
                    )
                } label: {
                    Label(
                        PalmiL10n.tr("searchConfiguration.remote.title"),
                        systemImage: "network"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("searchConfiguration.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            PalmiL10n.tr("remoteSearch.error.title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { remoteSearchStore.refresh() }
    }

    private func activate(_ mode: SearchConfigurationMode) {
        do {
            switch mode {
            case .local:
                try remoteSearchStore.activateConfiguration(nil)
            case .remote:
                guard let configuration = remoteSearchStore.preferredRemoteConfigurationSnapshot() else {
                    throw AppError.invalidState(
                        PalmiL10n.tr("searchConfiguration.remote.required")
                    )
                }
                try remoteSearchStore.activateConfiguration(configuration.id)
                permissionStore.setEnabled(true, for: .searchWeb)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
