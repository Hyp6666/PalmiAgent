import SwiftUI
import UIKit

/// 模型管理：主模型（两级菜单直接选）+ 模型分组（每组一块）+ OAuth 登录。
struct ModelHubScreen: View {
    @Bindable var store: ManualLabStore
    @State private var isAddingConnection = false
    @State private var isShowingCodexOAuth = false
    @State private var isShowingMigration = false
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }
    private var apiConnections: [ConnectionRecord] {
        ModelLibraryPresentation.sortedConnections(library).filter { $0.chatGPTAccount == nil }
    }
    private var oauthConnections: [ConnectionRecord] {
        ModelLibraryPresentation.sortedConnections(library).filter { $0.chatGPTAccount != nil }
    }

    var body: some View {
        Group {
            if library.availability.isReady {
                content
            } else {
                ContentUnavailableView(PalmiL10n.tr("ml.unavailable"), systemImage: "exclamationmark.triangle",
                                       description: Text(library.unavailableMessage))
            }
        }
        .navigationTitle(PalmiL10n.tr("settings.row.modelManagement"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { isAddingConnection = true } label: {
                        Label(PalmiL10n.tr("ml.add.model"), systemImage: "plus")
                    }
                    Section(PalmiL10n.tr("ml.add.oauth")) {
                        Button { isShowingCodexOAuth = true } label: {
                            Label("Codex OAuth", systemImage: "person.badge.key")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(PalmiL10n.tr("ml.add.model"))
                .disabled(!library.availability.isReady)
            }
        }
        .navigationDestination(isPresented: $isShowingCodexOAuth) {
            ChatGPTOAuthScreen(library: library)
        }
        .sheet(isPresented: $isAddingConnection) {
            NavigationStack { ConnectionEditorScreen(store: store, connectionID: nil) }
        }
        .sheet(isPresented: $isShowingMigration) {
            ModelLibraryMigrationSheet(library: library)
        }
        .modelLibraryErrorAlert($errorMessage)
        .onAppear {
            library.reconcileAllSources()
            if library.shouldPresentMigration { isShowingMigration = true }
        }
    }

    private var content: some View {
        List {
            Section {
                let status = ModelLibraryPresentation.mainModelStatus(library)
                ModelMenuRow(title: PalmiL10n.tr("ml.mainModel"), value: status.title, isProblem: status.isProblem) {
                    ModelLibraryMenuItems(library: library, selectedID: library.state.defaultMainModel.modelID) { id in
                        do { try library.setDefaultMainModel(id) } catch { errorMessage = error.localizedDescription }
                    }
                }
            }

            if !library.state.conflicts.isEmpty {
                Section {
                    NavigationLink {
                        ModelLibraryConflictsScreen(library: library)
                    } label: {
                        Label(PalmiL10n.tr("ml.conflicts.count", library.state.conflicts.count), systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.orange)
                    }
                }
            }

            ForEach(Array(apiConnections.enumerated()), id: \.element.id) { index, connection in
                Section {
                    connectionRow(connection)
                } header: {
                    if index == 0 { Text(PalmiL10n.tr("ml.groups.title")) }
                }
            }
            if apiConnections.isEmpty {
                Section(PalmiL10n.tr("ml.groups.title")) {
                    Button { isAddingConnection = true } label: {
                        Label(PalmiL10n.tr("ml.add.model"), systemImage: "plus.circle")
                    }
                }
            }

            ForEach(Array(oauthConnections.enumerated()), id: \.element.id) { index, connection in
                Section {
                    connectionRow(connection, title: "Codex OAuth")
                } header: {
                    if index == 0 { Text(PalmiL10n.tr("ml.add.oauth")) }
                }
            }
            if oauthConnections.isEmpty {
                Section(PalmiL10n.tr("ml.add.oauth")) {
                    NavigationLink { ChatGPTOAuthScreen(library: library) } label: { Text("Codex OAuth") }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func connectionRow(_ connection: ConnectionRecord, title: String? = nil) -> some View {
        NavigationLink {
            ConnectionDetailScreen(store: store, connectionID: connection.id)
        } label: {
            HStack {
                Text(title ?? connection.displayName).lineLimit(1)
                Spacer(minLength: 8)
                if ModelLibraryPresentation.connectionNeedsAttention(connection, library: library) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - 两级菜单选模型

/// 列表里的一行，点开就是菜单；右侧显示当前值。
struct ModelMenuRow<Content: View>: View {
    let title: String
    let value: String
    var icon: String? = nil
    var isProblem = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Label {
                        Text(title).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: icon).foregroundStyle(Color.accentColor)
                    }
                } else {
                    Text(title).foregroundStyle(.primary)
                }
                Spacer(minLength: 8)
                Text(value)
                    .lineLimit(1)
                    .foregroundStyle(isProblem ? Color.orange : Color.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
    }
}

/// 菜单内容：分组 → 模型。OAuth 分组单独放在“OAuth 登录”分节里。
struct ModelLibraryMenuItems: View {
    let library: ModelLibraryStore
    var followTitle: String? = nil
    let selectedID: UUID?
    var include: (ModelRecord) -> Bool = { !$0.imageGenerationOnly }
    let onSelect: (UUID?) -> Void

    var body: some View {
        if let followTitle {
            ModelMenuItem(title: followTitle, selected: selectedID == nil) { onSelect(nil) }
            Divider()
        }
        let groups = ModelLibraryPresentation.groups(library: library, models: library.state.models.filter(include))
        let oauth = groups.filter { library.state.connection($0.connectionID)?.chatGPTAccount != nil }
        ForEach(groups.filter { library.state.connection($0.connectionID)?.chatGPTAccount == nil }) { submenu($0, title: $0.title) }
        if !oauth.isEmpty {
            Section(PalmiL10n.tr("ml.add.oauth")) {
                ForEach(oauth) { submenu($0, title: "Codex OAuth") }
            }
        }
    }

    private func submenu(_ group: ModelLibraryPresentation.Group, title: String) -> some View {
        Menu {
            ForEach(group.models) { model in
                ModelMenuItem(title: model.title, selected: selectedID == model.id) { onSelect(model.id) }
            }
        } label: {
            if group.models.contains(where: { $0.id == selectedID }) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

struct ModelMenuItem: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

// MARK: - 添加 / 编辑分组

/// 添加时的模型草稿：保存分组时一并写入。
struct ModelDraftItem: Identifiable, Hashable {
    let id = UUID()
    var providerModelID: String
    var alias = ""
    var remoteDisplayName: String? = nil
    var canonicalID: String? = nil
    var ownedBy: String? = nil
    var wireProtocol: LLMWireProtocolPreference? = nil
    var supportsVision = false

    init(providerModelID: String, alias: String = "") {
        self.providerModelID = providerModelID
        self.alias = alias
    }

    init(_ model: LLMDiscoveredModel) {
        providerModelID = model.id
        remoteDisplayName = model.remoteDisplayName
        canonicalID = model.canonicalID
        ownedBy = model.ownedBy
    }

    var title: String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (remoteDisplayName ?? providerModelID) : trimmed
    }

    var draft: ModelDraft {
        ModelDraft(providerModelID: providerModelID, userAlias: alias, remoteDisplayName: remoteDisplayName,
                   canonicalID: canonicalID, ownedBy: ownedBy, wireProtocol: wireProtocol,
                   supportsVision: supportsVision ? true : nil)
    }
}

/// 添加或编辑一个模型分组：服务商、名称、地址、API Key；添加时一并加入模型。
struct ConnectionEditorScreen: View {
    @Bindable var store: ManualLabStore
    let connectionID: UUID?
    @Environment(\.dismiss) private var dismiss

    @State private var templateID: String = ""
    @State private var label = ""
    @State private var address = ""
    @State private var apiKey = ""
    @State private var originalKey = ""
    @State private var showsKey = false
    @State private var drafts: [ModelDraftItem] = []
    @State private var isFetching = false
    @State private var isAddingManually = false
    @State private var errorMessage: String?
    @State private var loaded = false

    private var library: ModelLibraryStore { store.modelLibrary }
    private var existing: ConnectionRecord? { connectionID.flatMap { library.state.connection($0) } }
    private var template: ConnectionTemplate? { ConnectionTemplateCatalog.template(templateID.isEmpty ? nil : templateID) }
    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var defaultProtocol: LLMWireProtocolPreference {
        existing?.endpoints.wireProtocolPreference ?? template?.protocolPreference ?? .automatic
    }

    var body: some View {
        Form {
            if connectionID == nil {
                Section {
                    Picker(PalmiL10n.tr("ml.connection.preset"), selection: $templateID) {
                        Text(PalmiL10n.tr("ml.connection.custom")).tag("")
                        ForEach(ConnectionTemplateCatalog.all) { Text($0.title).tag($0.id) }
                    }
                    .onChange(of: templateID) { _, _ in applyTemplate() }
                }
            }

            Section {
                LabeledContent(PalmiL10n.tr("ml.connection.label")) {
                    TextField(PalmiL10n.tr("ml.connection.label"), text: $label, prompt: Text(PalmiL10n.tr("ml.optional")))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(PalmiL10n.tr("ml.connection.address")) {
                    TextField(PalmiL10n.tr("ml.connection.address"), text: $address, prompt: Text(verbatim: "https://api.example.com/v1"))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent(PalmiL10n.tr("model.field.apiKey")) {
                    HStack(spacing: 8) {
                        Group {
                            if showsKey {
                                TextField(PalmiL10n.tr("model.field.apiKey"), text: $apiKey, prompt: Text(PalmiL10n.tr("ml.optional")))
                            } else {
                                SecureField(PalmiL10n.tr("model.field.apiKey"), text: $apiKey, prompt: Text(PalmiL10n.tr("ml.optional")))
                            }
                        }
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        Button { showsKey.toggle() } label: { Image(systemName: showsKey ? "eye.slash" : "eye") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }

            if connectionID == nil {
                Section(PalmiL10n.tr("ml.connection.models")) {
                    ForEach($drafts) { $item in
                        NavigationLink {
                            DraftModelScreen(item: $item, defaultProtocol: defaultProtocol) {
                                drafts.removeAll { $0.id == item.id }
                            }
                        } label: {
                            Text(item.title).lineLimit(1)
                        }
                    }
                    .onDelete { drafts.remove(atOffsets: $0) }
                    Button { isFetching = true } label: {
                        Label(PalmiL10n.tr("ml.add.fetch"), systemImage: "arrow.down.circle")
                    }
                    .disabled(trimmedAddress.isEmpty)
                    Button { isAddingManually = true } label: {
                        Label(PalmiL10n.tr("ml.add.manual"), systemImage: "plus.circle")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(PalmiL10n.tr(connectionID == nil ? "ml.add.model" : "common.edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("common.cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(PalmiL10n.tr("common.save")) { save() }
                    .disabled(trimmedAddress.isEmpty)
            }
        }
        .sheet(isPresented: $isFetching) {
            FetchModelsSheet(excludedIDs: Set(drafts.map(\.providerModelID))) {
                try await ModelDiscovery.fetch(endpoints: try endpoints(), apiKey: apiKey)
            } onImport: { models in
                drafts.append(contentsOf: models.map(ModelDraftItem.init))
            }
        }
        .sheet(isPresented: $isAddingManually) {
            ManualModelSheet { id, alias in
                drafts.append(ModelDraftItem(providerModelID: id, alias: alias))
            }
        }
        .modelLibraryErrorAlert($errorMessage)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let existing else { return }
        label = existing.userLabel ?? ""
        address = existing.endpoints.inputAddress
        templateID = existing.templateID ?? ""
        originalKey = library.credentialRead(for: existing).value ?? ""
        apiKey = originalKey
    }

    private func applyTemplate() {
        guard let template else { return }
        address = template.apiBase
        if label.isEmpty || ConnectionTemplateCatalog.all.contains(where: { $0.title == label }) { label = template.title }
    }

    /// 协议不在分组上选：预设带默认协议，自定义地址用“自动”；每个模型可以单独改。
    private func endpoints() throws -> ConnectionEndpointConfiguration {
        if let template, trimmedAddress == template.apiBase { return template.endpoints() }
        if let existing, trimmedAddress == existing.endpoints.inputAddress { return existing.endpoints }
        var endpoints = try ModelLibraryStore.endpoints(forCustomAddress: trimmedAddress, preference: defaultProtocol)
        endpoints.messagesSendsBearer = existing?.endpoints.messagesSendsBearer
        endpoints.geminiNativeBaseURL = existing?.endpoints.geminiNativeBaseURL
        endpoints.extraHeaders = existing?.endpoints.extraHeaders ?? [:]
        return endpoints
    }

    private func save() {
        do {
            let endpoints = try endpoints()
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if let connectionID {
                try library.updateConnection(
                    connectionID,
                    label: .some(trimmedLabel.isEmpty ? nil : trimmedLabel),
                    endpoints: endpoints,
                    newAPIKey: trimmedKey.isEmpty || trimmedKey == originalKey ? nil : trimmedKey,
                    clearAPIKey: trimmedKey.isEmpty && !originalKey.isEmpty
                )
            } else {
                let id = try library.addConnection(ConnectionDraft(
                    userLabel: trimmedLabel.isEmpty ? nil : trimmedLabel,
                    templateID: template?.id,
                    endpoints: endpoints,
                    apiKey: trimmedKey
                ))
                if !drafts.isEmpty { try library.addModels(connectionID: id, drafts: drafts.map(\.draft)) }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 添加流程中的单个模型：与模型详情同一套字段，另有移除。
struct DraftModelScreen: View {
    @Binding var item: ModelDraftItem
    let defaultProtocol: LLMWireProtocolPreference
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ModelFieldsSections(
                alias: $item.alias,
                aliasPrompt: item.remoteDisplayName ?? item.providerModelID,
                providerModelID: $item.providerModelID,
                wireProtocol: Binding(get: { item.wireProtocol ?? defaultProtocol }, set: { item.wireProtocol = $0 }),
                supportsVision: $item.supportsVision
            )
            Section {
                Button(PalmiL10n.tr("ml.model.remove"), role: .destructive) {
                    onRemove()
                    dismiss()
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("ml.model.detail"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 模型的可编辑字段：名称、模型 ID、协议、视觉。模型详情与添加流程共用。
struct ModelFieldsSections: View {
    @Binding var alias: String
    let aliasPrompt: String
    @Binding var providerModelID: String
    var providerIDEditable = true
    /// nil 时不显示协议（例如 OAuth 模型）。
    var wireProtocol: Binding<LLMWireProtocolPreference>?
    @Binding var supportsVision: Bool
    var onCommit: () -> Void = {}

    var body: some View {
        Section(PalmiL10n.tr("ml.model.name")) {
            TextField(PalmiL10n.tr("ml.model.name"), text: $alias, prompt: Text(aliasPrompt))
                .onSubmit(onCommit)
        }
        Section(PalmiL10n.tr("ml.model.providerID")) {
            TextField(PalmiL10n.tr("ml.model.providerID"), text: $providerModelID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.body.monospaced())
                .onSubmit(onCommit)
                .disabled(!providerIDEditable)
        }
        Section {
            if let wireProtocol {
                Picker(PalmiL10n.tr("model.connection.protocol.title"), selection: wireProtocol) {
                    ForEach(LLMWireProtocolPreference.allCases) { Text(ModelLibraryPresentation.protocolTitle($0)).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Toggle(PalmiL10n.tr("tool.facade.vision"), isOn: $supportsVision)
        }
    }
}

/// 自动获取：拉取模型列表，勾选后导入。
struct FetchModelsSheet: View {
    let excludedIDs: Set<String>
    let fetch: () async throws -> [LLMDiscoveredModel]
    let onImport: ([LLMDiscoveredModel]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var models: [LLMDiscoveredModel] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if models.isEmpty {
                    ContentUnavailableView(PalmiL10n.tr("ml.model.discoveryEmpty"), systemImage: "tray")
                } else {
                    List(models, id: \.id) { model in
                        Button {
                            if selected.contains(model.id) { selected.remove(model.id) } else { selected.insert(model.id) }
                        } label: {
                            HStack {
                                Text(model.remoteDisplayName ?? model.id).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(model.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(PalmiL10n.tr("ml.add.fetch"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PalmiL10n.tr("ml.add.import")) {
                        onImport(models.filter { selected.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .modelLibraryErrorAlert($errorMessage)
            .task { await load() }
        }
    }

    private func load() async {
        defer { isLoading = false }
        do {
            models = try await fetch().filter { !excludedIDs.contains($0.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 手动添加：填模型 ID，可选名称。
struct ManualModelSheet: View {
    let onAdd: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var modelID = ""
    @State private var alias = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(PalmiL10n.tr("ml.model.providerID")) {
                    TextField(PalmiL10n.tr("ml.model.providerID"), text: $modelID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                Section(PalmiL10n.tr("ml.model.name")) {
                    TextField(PalmiL10n.tr("ml.model.name"), text: $alias, prompt: Text(PalmiL10n.tr("ml.optional")))
                }
            }
            .navigationTitle(PalmiL10n.tr("ml.add.manual"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PalmiL10n.tr("ml.add.confirm")) {
                        onAdd(modelID.trimmingCharacters(in: .whitespacesAndNewlines), alias.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

enum ModelDiscovery {
    static func fetch(endpoints: ConnectionEndpointConfiguration, apiKey: String?) async throws -> [LLMDiscoveredModel] {
        let service = LLMModelDiscoveryService()
        if let modelsURL = endpoints.modelsURL.flatMap(URL.init(string:)) {
            return try await service.fetchModels(modelsURL: modelsURL, apiKey: apiKey,
                                                 wireProtocol: endpoints.wireProtocolPreference.explicitWireProtocol).models
        }
        return try await service.fetchModels(inputAddress: endpoints.inputAddress, apiKey: apiKey,
                                             protocolPreference: endpoints.wireProtocolPreference).models
    }
}

// MARK: - 分组详情

/// 分组详情：模型列表、自动获取 / 手动添加、地址与 API Key、删除。
struct ConnectionDetailScreen: View {
    @Bindable var store: ManualLabStore
    let connectionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var isDeleting = false
    @State private var isFetching = false
    @State private var isAddingManually = false
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }

    var body: some View {
        Group {
            if let connection = library.state.connection(connectionID) {
                content(connection)
            } else {
                ContentUnavailableView(PalmiL10n.tr("ml.connection.missing"), systemImage: "questionmark.folder")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditing) {
            NavigationStack { ConnectionEditorScreen(store: store, connectionID: connectionID) }
        }
        .modelLibraryErrorAlert($errorMessage)
    }

    private func content(_ connection: ConnectionRecord) -> some View {
        let models = library.state.models.filter { $0.connectionID == connection.id }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let isOAuth = connection.chatGPTAccount != nil
        return List {
            Section(PalmiL10n.tr("ml.connection.models")) {
                ForEach(models) { model in
                    NavigationLink {
                        ModelDetailScreen(store: store, modelID: model.id)
                    } label: {
                        Text(model.title).lineLimit(1)
                    }
                }
                .onDelete { offsets in
                    do { for index in offsets { try library.deleteModel(models[index].id) } }
                    catch { errorMessage = error.localizedDescription }
                }
                if !isOAuth {
                    Button { isFetching = true } label: {
                        Label(PalmiL10n.tr("ml.add.fetch"), systemImage: "arrow.down.circle")
                    }
                    Button { isAddingManually = true } label: {
                        Label(PalmiL10n.tr("ml.add.manual"), systemImage: "plus.circle")
                    }
                }
            }

            Section {
                if let account = connection.chatGPTAccount {
                    NavigationLink {
                        ChatGPTOAuthScreen(library: library)
                    } label: {
                        LabeledContent(PalmiL10n.tr("ml.connection.account"), value: account.email.isEmpty ? account.accountID : account.email)
                    }
                } else {
                    let credential = ModelLibraryPresentation.credentialStatus(connection, library: library)
                    LabeledContent(PalmiL10n.tr("ml.connection.address"), value: ModelLibraryURLDisplay.safeDisplay(connection.endpoints.inputAddress))
                    LabeledContent(PalmiL10n.tr("model.field.apiKey")) {
                        Text(credential.text).foregroundStyle(credential.isProblem ? Color.orange : Color.secondary)
                    }
                }
            }

            Section {
                Button(PalmiL10n.tr("common.delete"), role: .destructive) { isDeleting = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isOAuth ? "Codex OAuth" : connection.displayName)
        .toolbar {
            if !isOAuth {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(PalmiL10n.tr("common.edit")) { isEditing = true }
                }
            }
        }
        .sheet(isPresented: $isFetching) {
            FetchModelsSheet(excludedIDs: Set(models.map(\.providerModelID))) {
                try await ModelDiscovery.fetch(endpoints: connection.endpoints, apiKey: library.credentialRead(for: connection).value)
            } onImport: { items in
                add(items.map { ModelDraftItem($0).draft })
            }
        }
        .sheet(isPresented: $isAddingManually) {
            ManualModelSheet { id, alias in
                add([ModelDraftItem(providerModelID: id, alias: alias).draft])
            }
        }
        .confirmationDialog(PalmiL10n.tr("ml.connection.deleteConfirm", connection.displayName), isPresented: $isDeleting, titleVisibility: .visible) {
            Button(PalmiL10n.tr("common.delete"), role: .destructive) {
                do { try library.deleteConnection(connectionID); dismiss() } catch { errorMessage = error.localizedDescription }
            }
        } message: {
            let references = library.references(toConnection: connectionID)
            if !references.isEmpty { Text(PalmiL10n.tr("ml.delete.references", references.joined(separator: "、"))) }
        }
    }

    private func add(_ drafts: [ModelDraft]) {
        do { try library.addModels(connectionID: connectionID, drafts: drafts) } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - 模型详情

/// 模型详情：名称、模型 ID、协议、视觉；检查连通性、检查视觉、设为主模型、删除。
struct ModelDetailScreen: View {
    @Bindable var store: ManualLabStore
    let modelID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var providerModelID = ""
    @State private var loaded = false
    @State private var isDeleting = false
    @State private var connectivity: CheckState = .idle
    @State private var vision: CheckState = .idle
    @State private var errorMessage: String?

    enum CheckState: Equatable { case idle, running, passed, failed }

    private var library: ModelLibraryStore { store.modelLibrary }

    var body: some View {
        Group {
            if let model = library.state.model(modelID), let connection = library.state.connection(model.connectionID) {
                content(model, connection)
            } else {
                ContentUnavailableView(PalmiL10n.tr("model.error.modelMissing"), systemImage: "cube.transparent")
            }
        }
        .navigationTitle(PalmiL10n.tr("ml.model.detail"))
        .navigationBarTitleDisplayMode(.inline)
        .modelLibraryErrorAlert($errorMessage)
        .onDisappear(perform: saveNames)
    }

    private func content(_ model: ModelRecord, _ connection: ConnectionRecord) -> some View {
        let evidenceKey = ModelLibraryStore.evidenceKey(model: model, connection: connection)
        let isOAuth = connection.chatGPTAccount != nil
        return List {
            ModelFieldsSections(
                alias: $alias,
                aliasPrompt: model.remoteDisplayName ?? model.providerModelID,
                providerModelID: $providerModelID,
                providerIDEditable: !isOAuth,
                wireProtocol: isOAuth || model.imageGenerationOnly ? nil : Binding(
                    get: { model.wireProtocol(in: connection) },
                    set: { value in
                        do { try library.setModelWireProtocol(modelID, preference: value) }
                        catch { errorMessage = error.localizedDescription }
                    }
                ),
                supportsVision: Binding(
                    get: { model.capabilities.effectiveState(.visionInput, evidenceKey: evidenceKey) == .supported },
                    set: { value in
                        do { try library.setCapabilityDeclaration(modelID, kind: .visionInput, state: value ? .supported : .unsupported) }
                        catch { errorMessage = error.localizedDescription }
                    }
                ),
                onCommit: saveNames
            )

            if !model.imageGenerationOnly {
                Section {
                    checkButton(PalmiL10n.tr("ml.model.connectivity"), state: connectivity) { await checkConnectivity() }
                    checkButton(PalmiL10n.tr("ml.model.checkVision"), state: vision) { await checkVision() }
                }
                Section {
                    if library.state.defaultMainModel.modelID == modelID {
                        LabeledContent(PalmiL10n.tr("ml.mainModel")) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    } else {
                        Button(PalmiL10n.tr("ml.model.setMain")) {
                            do { try library.setDefaultMainModel(modelID) } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
            }

            Section {
                Button(PalmiL10n.tr("ml.model.delete"), role: .destructive) { isDeleting = true }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            alias = model.userAlias ?? ""
            providerModelID = model.providerModelID
        }
        .confirmationDialog(PalmiL10n.tr("ml.model.deleteConfirm", model.title), isPresented: $isDeleting, titleVisibility: .visible) {
            Button(PalmiL10n.tr("common.delete"), role: .destructive) {
                do { try library.deleteModel(modelID); dismiss() } catch { errorMessage = error.localizedDescription }
            }
        } message: {
            let references = library.references(toModel: modelID)
            if !references.isEmpty { Text(PalmiL10n.tr("ml.delete.references", references.joined(separator: "、"))) }
        }
    }

    private func checkButton(_ title: String, state: CheckState, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                switch state {
                case .idle: EmptyView()
                case .running: ProgressView()
                case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
                }
            }
        }
        .disabled(state == .running)
    }

    private func saveNames() {
        guard loaded, let model = library.state.model(modelID) else { return }
        let trimmedID = providerModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedAlias != (model.userAlias ?? "") || trimmedID != model.providerModelID else { return }
        do { try library.updateModel(modelID, alias: trimmedAlias, providerModelID: trimmedID) }
        catch { errorMessage = error.localizedDescription }
    }

    /// 发一条只含文字的短请求，确认地址与凭据可用。结果不影响模型的使用。
    private func checkConnectivity() async {
        connectivity = .running
        let reply = await send(AgentModelMessage.user("Reply with OK only."))
        connectivity = reply == nil ? .failed : .passed
    }

    /// 发一张纯红色图片问颜色；答对即视为能看图，并打开视觉开关。答错或报错只显示失败，不改动开关。
    private func checkVision() async {
        vision = .running
        guard let image = Self.visionProbeDataURL() else { vision = .failed; return }
        var message = AgentModelMessage.user("What color is this image? Reply with one word.")
        message.imageDataURLs = [image]
        guard let reply = await send(message)?.lowercased() else { vision = .failed; return }
        if reply.contains("red") || reply.contains("红") {
            vision = .passed
            try? library.setCapabilityDeclaration(modelID, kind: .visionInput, state: .supported)
        } else {
            vision = .failed
            errorMessage = reply
        }
    }

    private func send(_ message: AgentModelMessage) async -> String? {
        saveNames()
        switch library.resolveModel(modelID, asMainModel: false) {
        case .failure(let issue):
            errorMessage = issue.localizedDescription
            return nil
        case .success(let resolved):
            do {
                let response = try await store.modelRuntime.complete(AgentModelRequest(
                    selection: AgentModelSelection(providerID: .customOpenAI, modelRole: .reasoningModel, reasoning: .disabled,
                                                   configurationOverride: .resolved(resolved.configuration)),
                    apiMessages: [message],
                    tools: [], toolIntent: .none
                ))
                return response.message.textContent
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }
    }

    private static func visionProbeDataURL() -> String? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return image.jpegData(compressionQuality: 0.9).map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
    }
}

/// 冲突处理：新旧版本同时修改同一关键字段时保留双方的值，由用户决定。
struct ModelLibraryConflictsScreen: View {
    let library: ModelLibraryStore
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(library.state.conflicts) { conflict in
                Section(conflict.field) {
                    LabeledContent(PalmiL10n.tr("ml.conflicts.current"), value: conflict.currentValue ?? "—")
                    LabeledContent(PalmiL10n.tr("ml.conflicts.legacy"), value: conflict.legacyValue ?? PalmiL10n.tr("ml.conflicts.deleted"))
                    Button(PalmiL10n.tr("ml.conflicts.keepCurrent")) { resolve(conflict, keepCurrent: true) }
                    Button(PalmiL10n.tr("ml.conflicts.useLegacy")) { resolve(conflict, keepCurrent: false) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("ml.conflicts.title"))
        .navigationBarTitleDisplayMode(.inline)
        .modelLibraryErrorAlert($errorMessage)
    }

    private func resolve(_ conflict: ModelLibraryConflict, keepCurrent: Bool) {
        do { try library.resolveConflict(conflict.id, keepCurrent: keepCurrent) } catch { errorMessage = error.localizedDescription }
    }
}

extension View {
    func modelLibraryErrorAlert(_ message: Binding<String?>) -> some View {
        alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(message.wrappedValue ?? "") }
    }
}
