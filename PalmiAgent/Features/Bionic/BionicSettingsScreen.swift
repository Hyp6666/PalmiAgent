import SwiftUI
import PhotosUI
import UIKit

/// 角色的主模型选择：跟随默认主模型，或明确指定模型库中的一个模型。
/// 选择写入草稿的 `model_library_binding`，保存时转入模型库作用域绑定，不写进角色存档。
struct BionicModelBindingFields: View {
    static let draftKey = "model_library_binding"
    @Bindable var store: BionicStore
    @Binding var binding: BionicObject
    @State private var showsHelp = false

    private var library: ModelLibraryStore { store.model.library }
    private var instance: String? { binding.optionalText("installation_id") }
    private var current: String {
        if let draft = binding.optionalText(Self.draftKey) { return draft }
        guard let instance else { return "" }
        return library.scopeBinding(.bionic(instance)).explicitModelID?.uuidString ?? ""
    }
    private var selectableModels: [ModelRecord] {
        library.state.models.filter { !$0.imageGenerationOnly }
    }

    var body: some View {
        Section {
            Picker(PalmiL10n.tr("ml.mainModel"), selection: Binding(get: { current }, set: {
                binding[Self.draftKey] = .string($0)
            })) {
                Text(defaultTitle).tag("")
                ForEach(selectableModels) { model in
                    Text(ModelLibraryPresentation.modelTitle(model, library: library)).tag(model.id.uuidString)
                }
                if !current.isEmpty, !selectableModels.contains(where: { $0.id.uuidString == current }) {
                    Text(PalmiL10n.tr("ml.binding.invalid")).tag(current)
                }
            }
        } header: {
            HStack {
                Text(PalmiL10n.tr("bionic.models"))
                Button { showsHelp = true } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(PalmiL10n.tr("bionic.models"))
            }
        } footer: {
            Text(PalmiL10n.tr("ml.bionic.footer"))
        }
        .alert(PalmiL10n.tr("bionic.models"), isPresented: $showsHelp) {
            Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {}
        } message: { Text(PalmiL10n.tr("ml.bionic.help")) }
    }

    private var defaultTitle: String {
        let name = library.state.defaultMainModel.modelID.flatMap { library.state.model($0) }
            .map { ModelLibraryPresentation.modelTitle($0, library: library) }
        return name.map { PalmiL10n.tr("ml.followDefaultNamed", $0) } ?? PalmiL10n.tr("ml.followDefault")
    }

    /// 草稿值 → 作用域绑定；nil 表示草稿未改动。
    static func drafted(_ binding: BionicObject) -> ScopedMainModelBinding? {
        guard let raw = binding.optionalText(draftKey) else { return nil }
        if raw.isEmpty { return .inherit }
        return UUID(uuidString: raw).map(ScopedMainModelBinding.explicitModel)
    }
}

struct BionicSettingsScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    var body: some View { BionicPersonaEditor(store: store, instance: instance) }
}

struct BionicMigrationScreen: View {
    private struct Share: Identifiable { let id = UUID(); let url: URL }
    @Bindable var store: BionicStore
    let instance: String
    @State private var exporting = false
    @State private var confirmation = false
    @State private var share: Share?
    @State private var sharedURL: URL?
    @State private var errorText: String?
    var body: some View {
        List {
            Button { confirmation = true } label: {
                HStack {
                    Label(PalmiL10n.tr("bionic.export"), systemImage: "square.and.arrow.up")
                    Spacer()
                    if exporting { ProgressView() }
                }
            }
            .disabled(exporting)
            .alert(PalmiL10n.tr("bionic.export"), isPresented: $confirmation) {
                Button(PalmiL10n.tr("bionic.confirmExport")) {
                    exporting = true
                    Task {
                        defer { exporting = false }
                        do {
                            let url = try await store.migration.export(instance)
                            sharedURL = url; share = Share(url: url)
                        } catch { errorText = BionicStore.errorText(error) }
                    }
                }
                Button(PalmiL10n.tr("bionic.cancel"), role: .cancel) { confirmation = false }
            } message: { Text(PalmiL10n.tr("bionic.exportPrivacy")) }
        }
        .navigationTitle(PalmiL10n.tr("bionic.migration")).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share, onDismiss: {
            if let url = sharedURL { store.migration.finishSharing(url); sharedURL = nil }
        }) { item in BionicShareSheet(url: item.url) }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }
}

struct BionicImportScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: BionicStore
    let prepared: BionicMigrationService.PreparedImport
    @State private var mode = "same_person"
    @State private var continueContact = false
    @State private var binding: BionicObject = [:]
    @State private var busy = false
    @State private var installed = false
    @State private var errorText: String?
    var body: some View {
        Form {
            Section(PalmiL10n.tr("bionic.profile")) {
                LabeledContent(PalmiL10n.tr("bionic.nickname"), value: prepared.role.name)
                LabeledContent(PalmiL10n.tr("bionic.nativeLanguage"), value: BionicPersonaCatalog.languageNames[prepared.role.persona.text("native_language")] ?? "")
                LabeledContent(PalmiL10n.tr("bionic.messageCount"), value: String(prepared.role.state.order.count))
                LabeledContent(PalmiL10n.tr("bionic.memoryCount"), value: String(prepared.role.state.raw.object("confirmed_memory_revision_ids").count))
                Text(PalmiL10n.tr("bionic.importNotice")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker(PalmiL10n.tr("bionic.importMode"), selection: $mode) {
                    Text(PalmiL10n.tr("bionic.samePerson")).tag("same_person")
                    Text(PalmiL10n.tr("bionic.newPerson")).tag("new_person")
                }
                if mode == "new_person" {
                    Text(PalmiL10n.tr("bionic.newPersonNotice")).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle(PalmiL10n.tr("bionic.resumeContact"), isOn: $continueContact)
            }
            BionicModelBindingFields(store: store, binding: $binding)
            Section {
                if busy { ProgressView(PalmiL10n.tr("bionic.importing")) }
                Button(PalmiL10n.tr("bionic.validateAndImport")) {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            let role = try await store.migration.install(prepared, mode: mode,
                                name: BionicUserProfileStore.shared.displayName, avatar: BionicUserProfileStore.shared.avatarPNG,
                                binding: binding, continueContact: continueContact, language: PalmiLanguage.current.rawValue)
                            installed = true; await store.refresh(); await store.open(role.installationID); dismiss()
                        } catch { errorText = BionicStore.errorText(error) }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .bionicKeyboardDismissOnOutsideTap()
        .disabled(busy)
        .navigationTitle(PalmiL10n.tr("bionic.import"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("bionic.cancel")) { dismiss() }.disabled(busy) } }
        .onAppear { if binding.isEmpty { binding = store.model.defaultBinding() } }
        .onDisappear { if !installed && !busy { store.migration.discard(prepared) } }
        .interactiveDismissDisabled(busy)
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) {} } message: { Text(errorText ?? "") }
    }
}

private struct BionicShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
