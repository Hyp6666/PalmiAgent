import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BionicRootScreen: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Bindable var store: BionicStore
    let onOpenSettings: () -> Void
    let onSelectMode: (AppShellMode) -> Void
    @State private var creating = false
    @State private var importing = false
    @State private var adding = false
    @State private var preparing = false
    @State private var prepared: BionicMigrationService.PreparedImport?
    @State private var errorText: String?
    var body: some View {
        Group {
            if sizeClass == .compact {
                NavigationStack(path: $store.path) {
                    home.navigationDestination(for: String.self) { id in BionicChatScreen(store: store, instance: id).id(id) }
                }
            } else {
                NavigationSplitView { home } detail: {
                    if let id = store.selectedID { NavigationStack { BionicChatScreen(store: store, instance: id).id(id) } }
                    else { ContentUnavailableView(PalmiL10n.tr("bionic.chooseRole"), systemImage: "bubble.left.and.bubble.right") }
                }
            }
        }
        .task { await store.refresh() }
        .confirmationDialog(PalmiL10n.tr("common.add"), isPresented: $adding, titleVisibility: .hidden) {
            Button(PalmiL10n.tr("bionic.create")) { creating = true }
            Button(PalmiL10n.tr("bionic.import")) { importing = true }
        }
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
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil || store.globalError != nil }, set: {
            if !$0 { errorText = nil; store.globalError = nil }
        })) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) { errorText = nil; store.globalError = nil } }
        message: { Text(errorText ?? store.globalError ?? "") }
    }
    private var home: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            if store.roles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    Text(PalmiL10n.tr("bionic.noRoles")).font(.headline)
                    Text(PalmiL10n.tr("bionic.emptyHint")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(28).frame(maxWidth: 340).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.roles, id: \.installationID) { role in
                            Button { Task { await store.open(role.installationID) } } label: {
                                HStack(alignment: .center, spacing: 12) {
                                    BionicAvatar(data: store.avatars[role.installationID + ":" + role.characterID], name: role.name, size: 52)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(role.name).font(.headline).foregroundStyle(.primary)
                                        Text(store.lastBodies[role.installationID].flatMap { $0.isEmpty ? nil : $0 } ?? role.persona.text("identity"))
                                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 12)
                                    if let count = store.unreadCounts[role.installationID], count > 0 {
                                        Text(count > 99 ? "99+" : String(count)).font(.caption2.bold())
                                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4).background(.tint, in: Capsule())
                                    }
                                }
                                .padding(.horizontal, 20).padding(.vertical, 14).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if role.installationID != store.roles.last?.installationID { Divider().padding(.leading, 84) }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            if preparing { ProgressView(PalmiL10n.tr("bionic.importPreparing")).padding(20).background(.regularMaterial, in: .rect(cornerRadius: 16)) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            AppShellTopBar(mode: .bionic, trailingSystemName: "plus", trailingAccessibilityLabel: PalmiL10n.tr("common.add"),
                           onOpenSettings: onOpenSettings, onTrailingAction: { adding = true }, onSelectMode: onSelectMode)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
                .background(Color(uiColor: .systemGroupedBackground))
        }
    }
}

struct BionicAvatar: View {
    let data: Data?
    let name: String
    var size: CGFloat = 36
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Text(String(name.prefix(1))).font(.system(size: size * 0.42, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.accentColor.opacity(0.12)) }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
        .task(id: data) { image = data.flatMap { UIImage(data: $0) } }
    }
}
