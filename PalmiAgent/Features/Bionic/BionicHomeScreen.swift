import SwiftUI
import UniformTypeIdentifiers

struct BionicRootScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Bindable var store: BionicStore
    let onOpenSettings: () -> Void
    let onSelectMode: (AppShellMode) -> Void
    @State private var creating = false
    @State private var importing = false
    @State private var preparing = false
    @State private var prepared: BionicMigrationService.PreparedImport?
    @State private var errorText: String?

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                NavigationStack(path: $store.path) {
                    home.navigationDestination(for: String.self) { id in BionicChatScreen(store: store, instance: id) }
                }
            } else {
                NavigationSplitView {
                    home
                } detail: {
                    if let id = store.selectedID { NavigationStack { BionicChatScreen(store: store, instance: id).id(id) } }
                    else { ContentUnavailableView(PalmiL10n.tr("bionic.chooseRole"), systemImage: "person.crop.circle", description: Text(PalmiL10n.tr("bionic.emptyDescription"))) }
                }
            }
        }
        .task { await store.refresh() }
        .sheet(isPresented: $creating) { NavigationStack { BionicPersonaEditor(store: store, instance: nil) } }
        .sheet(item: $prepared) { item in NavigationStack { BionicImportScreen(store: store, prepared: item) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url):
                preparing = true
                Task {
                    defer { preparing = false }
                    do { prepared = try await store.migration.prepare(url) }
                    catch { errorText = BionicStore.errorText(error) }
                }
            case .failure(let error): errorText = error.localizedDescription
            }
        }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil || store.globalError != nil }, set: { if !$0 { errorText = nil; store.globalError = nil } })) {
            Button(PalmiL10n.tr("bionic.ok"), role: .cancel) { errorText = nil; store.globalError = nil }
        } message: { Text(errorText ?? store.globalError ?? "") }
    }
    private var home: some View {
        List {
            if preparing { HStack { ProgressView(); Text(PalmiL10n.tr("bionic.importPreparing")) } }
            if store.roles.isEmpty {
                ContentUnavailableView(PalmiL10n.tr("bionic.noRoles"), systemImage: "person.crop.circle.badge.plus", description: Text(PalmiL10n.tr("bionic.emptyDescription")))
                    .listRowBackground(Color.clear)
                Button(PalmiL10n.tr("bionic.create")) { creating = true }
                Button(PalmiL10n.tr("bionic.import")) { importing = true }
            } else {
                ForEach(store.roles, id: \.installationID) { role in
                    Button { Task { await store.open(role.installationID) } } label: {
                        HStack(spacing: 14) {
                            BionicAvatar(data: store.avatars[role.installationID + ":" + role.characterID], name: role.name, size: 52)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(role.name).font(.headline).foregroundStyle(.primary)
                                Text(store.lastBodies[role.installationID] ?? role.persona.text("identity")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if let n = store.unreadCounts[role.installationID], n > 0 {
                                Text(n > 99 ? "99+" : String(n)).font(.caption2.bold()).padding(6).foregroundStyle(.white).background(.tint, in: Capsule())
                            }
                        }.padding(.vertical, 7)
                    }.buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(PalmiL10n.tr("appMode.bionic"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(AppShellMode.chat.title) { onSelectMode(.chat) }
                    Button(AppShellMode.professional.title) { onSelectMode(.professional) }
                    Button(AppShellMode.bionic.title) { onSelectMode(.bionic) }
                    Divider()
                    Button(PalmiL10n.tr("bionic.appSettings"), action: onOpenSettings)
                } label: { Image(systemName: "chevron.down.circle") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(PalmiL10n.tr("bionic.create"), systemImage: "person.badge.plus") { creating = true }
                    Button(PalmiL10n.tr("bionic.import"), systemImage: "square.and.arrow.down") { importing = true }
                } label: { Image(systemName: "plus") }
            }
        }
    }
}

struct BionicAvatar: View {
    let data: Data?
    let name: String
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
            else { Text(String(name.prefix(1))).font(.system(size: size * 0.42, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.accentColor.opacity(0.12)) }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}
