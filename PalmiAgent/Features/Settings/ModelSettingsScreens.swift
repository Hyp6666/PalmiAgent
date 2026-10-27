import SwiftUI

/// 模型管理：主模型 + 模型库（按来源分组）。添加入口在右上角。
struct ModelHubScreen: View {
    @Bindable var store: ManualLabStore
    @State private var isAddingConnection = false
    @State private var isShowingCodexOAuth = false
    @State private var isShowingMigration = false

    private var library: ModelLibraryStore { store.modelLibrary }

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
        .onAppear {
            library.reconcileAllSources()
            if library.shouldPresentMigration { isShowingMigration = true }
        }
    }

    private var content: some View {
        List {
            Section {
                NavigationLink {
                    ModelLibraryPickerScreen(
                        library: library,
                        title: PalmiL10n.tr("ml.mainModel"),
                        followTitle: nil,
                        selectedID: library.state.defaultMainModel.modelID,
                        onSelect: { try library.setDefaultMainModel($0) }
                    )
                } label: {
                    let status = ModelLibraryPresentation.mainModelStatus(library)
                    LabeledContent(PalmiL10n.tr("ml.mainModel")) {
                        Text(status.title)
                            .foregroundStyle(status.isProblem ? Color.orange : Color.secondary)
                            .lineLimit(1)
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

            Section(PalmiL10n.tr("ml.library.title")) {
                ForEach(ModelLibraryPresentation.sortedConnections(library)) { connection in
                    NavigationLink {
                        ConnectionDetailScreen(store: store, connectionID: connection.id)
                    } label: {
                        HStack {
                            Text(connection.displayName).lineLimit(1)
                            Spacer(minLength: 8)
                            if ModelLibraryPresentation.connectionNeedsAttention(connection, library: library) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if library.state.connections.isEmpty {
                    Button { isAddingConnection = true } label: {
                        Label(PalmiL10n.tr("ml.add.model"), systemImage: "plus.circle")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// 从模型库里选一个模型：主模型、视觉、审核模型都用这一套。
struct ModelLibraryPickerScreen: View {
    let library: ModelLibraryStore
    let title: String
    /// 非 nil 时第一行是“跟随”选项，选中它传 nil。
    let followTitle: String?
    let selectedID: UUID?
    let onSelect: (UUID?) throws -> Void
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let followTitle {
                Section {
                    row(followTitle, selected: selectedID == nil) { apply(nil) }
                }
            }
            ForEach(ModelLibraryPresentation.groups(library: library, models: library.state.models.filter { !$0.imageGenerationOnly })) { group in
                Section(group.title) {
                    ForEach(group.models) { model in
                        row(model.title, selected: selectedID == model.id) { apply(model.id) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .modelLibraryErrorAlert($errorMessage)
    }

    private func row(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func apply(_ id: UUID?) {
        do {
            try onSelect(id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 添加或编辑一个来源：服务商、名称、地址、API Key；添加时顺带挑选模型。
struct ConnectionEditorScreen: View {
    @Bindable var store: ManualLabStore
    let connectionID: UUID?
    @Environment(\.dismiss) private var dismiss

    @State private var templateID: String = ""
    @State private var label = ""
    @State private var address = ""
    @State private var apiKey = ""
    @State private var showsKey = false
    @State private var picker = ModelIDPickerState()
    @State private var errorMessage: String?
    @State private var loaded = false

    private var library: ModelLibraryStore { store.modelLibrary }
    private var existing: ConnectionRecord? { connectionID.flatMap { library.state.connection($0) } }
    private var template: ConnectionTemplate? { ConnectionTemplateCatalog.template(templateID.isEmpty ? nil : templateID) }
    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

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
                            let prompt = Text(PalmiL10n.tr(existing?.credentialReference == nil ? "ml.optional" : "ml.credential.saved"))
                            if showsKey {
                                TextField(PalmiL10n.tr("model.field.apiKey"), text: $apiKey, prompt: prompt)
                            } else {
                                SecureField(PalmiL10n.tr("model.field.apiKey"), text: $apiKey, prompt: prompt)
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
                ModelIDPickerSections(state: $picker, existingIDs: []) {
                    try await discover()
                }
                .disabled(trimmedAddress.isEmpty)
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
    }

    private func applyTemplate() {
        guard let template else { return }
        address = template.apiBase
        if label.isEmpty || ConnectionTemplateCatalog.all.contains(where: { $0.title == label }) { label = template.title }
    }

    /// 协议不在来源上选：预设带默认协议，自定义地址用“自动”；每个模型可在详情里单独改。
    private func endpoints() throws -> ConnectionEndpointConfiguration {
        if let template, trimmedAddress == template.apiBase { return template.endpoints() }
        if let existing, trimmedAddress == existing.endpoints.inputAddress { return existing.endpoints }
        var endpoints = try ModelLibraryStore.endpoints(
            forCustomAddress: trimmedAddress,
            preference: existing?.endpoints.wireProtocolPreference ?? .automatic
        )
        endpoints.messagesSendsBearer = existing?.endpoints.messagesSendsBearer
        endpoints.geminiNativeBaseURL = existing?.endpoints.geminiNativeBaseURL
        endpoints.extraHeaders = existing?.endpoints.extraHeaders ?? [:]
        return endpoints
    }

    private func discover() async throws -> [LLMDiscoveredModel] {
        try await ModelDiscovery.fetch(endpoints: try endpoints(), apiKey: apiKey)
    }

    private func save() {
        do {
            let endpoints = try endpoints()
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if let connectionID {
                try library.updateConnection(
                    connectionID,
                    label: .some(trimmedLabel.isEmpty ? nil : trimmedLabel),
                    endpoints: endpoints,
                    newAPIKey: apiKey.isEmpty ? nil : apiKey,
                    clearAPIKey: false
                )
            } else {
                let id = try library.addConnection(ConnectionDraft(
                    userLabel: trimmedLabel.isEmpty ? nil : trimmedLabel,
                    templateID: template?.id,
                    endpoints: endpoints,
                    apiKey: apiKey
                ))
                let drafts = picker.selectedDrafts
                if !drafts.isEmpty { try library.addModels(connectionID: id, drafts: drafts) }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 来源详情：模型列表、添加模型、连接信息、删除。
struct ConnectionDetailScreen: View {
    @Bindable var store: ManualLabStore
    let connectionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var isDeleting = false
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
                    NavigationLink {
                        AddModelsScreen(store: store, connectionID: connection.id)
                    } label: {
                        Label(PalmiL10n.tr("ml.add.model"), systemImage: "plus.circle")
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
        .navigationTitle(connection.displayName)
        .toolbar {
            if !isOAuth {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(PalmiL10n.tr("common.edit")) { isEditing = true }
                }
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
}

/// 往已有来源里加模型：拉取列表勾选，或手动输入模型 ID。
struct AddModelsScreen: View {
    @Bindable var store: ManualLabStore
    let connectionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var picker = ModelIDPickerState()
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }

    var body: some View {
        let existingIDs = Set(library.state.models.filter { $0.connectionID == connectionID }.map(\.providerModelID))
        Form {
            ModelIDPickerSections(state: $picker, existingIDs: existingIDs) {
                guard let connection = library.state.connection(connectionID) else { return [] }
                return try await ModelDiscovery.fetch(endpoints: connection.endpoints, apiKey: library.credentialRead(for: connection).value)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(PalmiL10n.tr("ml.add.model"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(PalmiL10n.tr("ml.add.confirm")) {
                    do {
                        try library.addModels(connectionID: connectionID, drafts: picker.selectedDrafts)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .disabled(picker.selected.isEmpty)
            }
        }
        .modelLibraryErrorAlert($errorMessage)
    }
}

/// 模型 ID 选择的草稿：拉取到的列表 + 手动输入的 ID，两者统一勾选。
struct ModelIDPickerState {
    var available: [LLMDiscoveredModel] = []
    var selected: Set<String> = []
    var manualID = ""
    var isFetching = false

    var selectedDrafts: [ModelDraft] {
        available.filter { selected.contains($0.id) }.map {
            ModelDraft(providerModelID: $0.id, userAlias: nil, remoteDisplayName: $0.remoteDisplayName,
                       canonicalID: $0.canonicalID, ownedBy: $0.ownedBy)
        }
    }
}

struct ModelIDPickerSections: View {
    @Binding var state: ModelIDPickerState
    let existingIDs: Set<String>
    let fetch: () async throws -> [LLMDiscoveredModel]
    @State private var errorMessage: String?

    var body: some View {
        Section(PalmiL10n.tr("ml.connection.models")) {
            Button {
                Task { await load() }
            } label: {
                HStack {
                    Label(PalmiL10n.tr("model.discovery.fetch"), systemImage: "arrow.clockwise")
                    if state.isFetching { Spacer(); ProgressView() }
                }
            }
            .disabled(state.isFetching)
            ForEach(state.available.filter { !existingIDs.contains($0.id) }, id: \.id) { model in
                Button {
                    if state.selected.contains(model.id) { state.selected.remove(model.id) } else { state.selected.insert(model.id) }
                } label: {
                    HStack {
                        Text(model.remoteDisplayName ?? model.id).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: state.selected.contains(model.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(state.selected.contains(model.id) ? Color.accentColor : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                TextField(PalmiL10n.tr("ml.model.manualPlaceholder"), text: $state.manualID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(addManual)
                Button(action: addManual) { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(state.manualID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(PalmiL10n.tr("ml.add.confirm"))
            }
        }
        .modelLibraryErrorAlert($errorMessage)
    }

    private func addManual() {
        let id = state.manualID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if !state.available.contains(where: { $0.id == id }) {
            state.available.append(LLMDiscoveredModel(id: id, ownedBy: nil))
        }
        state.selected.insert(id)
        state.manualID = ""
    }

    private func load() async {
        state.isFetching = true
        defer { state.isFetching = false }
        do {
            let models = try await fetch()
            let manual = state.available.filter { item in !models.contains { $0.id == item.id } && state.selected.contains(item.id) }
            state.available = models + manual
            if models.isEmpty { errorMessage = PalmiL10n.tr("ml.model.discoveryEmpty") }
        } catch {
            errorMessage = error.localizedDescription
        }
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

/// 模型详情：名称、模型 ID、协议、能力、连通性检查、设为主模型、删除。
struct ModelDetailScreen: View {
    @Bindable var store: ManualLabStore
    let modelID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var providerModelID = ""
    @State private var loaded = false
    @State private var isDeleting = false
    @State private var connectivity: Bool?
    @State private var isChecking = false
    @State private var errorMessage: String?

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
            Section(PalmiL10n.tr("ml.model.name")) {
                TextField(PalmiL10n.tr("ml.model.name"), text: $alias, prompt: Text(model.remoteDisplayName ?? model.providerModelID))
                    .onSubmit(saveNames)
            }

            Section(PalmiL10n.tr("ml.model.providerID")) {
                TextField(PalmiL10n.tr("ml.model.providerID"), text: $providerModelID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                    .onSubmit(saveNames)
                    .disabled(isOAuth)
            }

            if !model.imageGenerationOnly {
                Section {
                    if !isOAuth {
                        Picker(PalmiL10n.tr("model.connection.protocol.title"), selection: Binding(
                            get: { model.wireProtocol(in: connection) },
                            set: { value in
                                do { try library.setModelWireProtocol(modelID, preference: value) }
                                catch { errorMessage = error.localizedDescription }
                            }
                        )) {
                            ForEach(LLMWireProtocolPreference.allCases) { Text(ModelLibraryPresentation.protocolTitle($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    capabilityToggle(.visionInput, model: model, evidenceKey: evidenceKey) { $0 == .supported }
                    capabilityToggle(.toolCalls, model: model, evidenceKey: evidenceKey) { $0 != .unsupported }
                }

                Section {
                    Button {
                        Task { await checkConnectivity() }
                    } label: {
                        HStack {
                            Text(PalmiL10n.tr("ml.model.connectivity"))
                            Spacer()
                            if isChecking {
                                ProgressView()
                            } else if let connectivity {
                                Image(systemName: connectivity ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(connectivity ? Color.green : Color.red)
                            }
                        }
                    }
                    .disabled(isChecking)
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

    /// 能力开关直接写手动声明：打开即“支持”，关闭即“不支持”。
    private func capabilityToggle(
        _ kind: ModelCapabilityKind,
        model: ModelRecord,
        evidenceKey: String,
        isOn: @escaping (ModelCapabilityState) -> Bool
    ) -> some View {
        Toggle(ModelLibraryPresentation.capabilityTitle(kind), isOn: Binding(
            get: { isOn(model.capabilities.effectiveState(kind, evidenceKey: evidenceKey)) },
            set: { value in
                do { try library.setCapabilityDeclaration(modelID, kind: kind, state: value ? .supported : .unsupported) }
                catch { errorMessage = error.localizedDescription }
            }
        ))
    }

    private func saveNames() {
        guard loaded, let model = library.state.model(modelID) else { return }
        let trimmedID = providerModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedAlias != (model.userAlias ?? "") || trimmedID != model.providerModelID else { return }
        do { try library.updateModel(modelID, alias: trimmedAlias, providerModelID: trimmedID) }
        catch { errorMessage = error.localizedDescription }
    }

    /// 只确认地址与凭据可用，不代表任何能力。
    private func checkConnectivity() async {
        saveNames()
        isChecking = true
        defer { isChecking = false }
        switch library.resolveModel(modelID, asMainModel: false) {
        case .failure(let issue):
            connectivity = false
            errorMessage = issue.localizedDescription
        case .success(let resolved):
            do {
                _ = try await store.modelRuntime.complete(AgentModelRequest(
                    selection: AgentModelSelection(providerID: .customOpenAI, modelRole: .reasoningModel, reasoning: .disabled,
                                                   configurationOverride: .resolved(resolved.configuration)),
                    apiMessages: [.user("Reply with OK only.")],
                    tools: [], toolIntent: .none
                ))
                connectivity = true
            } catch {
                connectivity = false
                errorMessage = error.localizedDescription
            }
        }
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
