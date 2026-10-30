import SwiftUI

/// 模型管理：主模型（两级菜单直接选）+ API 分组（每组一块）+ OAuth 分组。
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
                            Label { Text("Codex OAuth") } icon: { CodexOAuthLogo.menuImage() }
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
                    if index == 0 { Text(PalmiL10n.tr("ml.oauth.groups")) }
                }
            }
            if oauthConnections.isEmpty {
                Section(PalmiL10n.tr("ml.oauth.groups")) {
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

// MARK: - 添加 / 编辑分组

/// 添加或编辑一个 API 分组：服务商、名称、地址、API Key；添加时一并加入模型。
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
    private var probe: ModelProbe? {
        (try? endpoints()).map { ModelProbe(runtime: store.modelRuntime, endpoints: $0, apiKey: apiKey) }
    }

    var body: some View {
        Form {
            if connectionID == nil {
                Section {
                    ChoiceMenuRow(
                        title: PalmiL10n.tr("ml.connection.preset"),
                        selection: Binding(get: { templateID }, set: { templateID = $0; applyTemplate() }),
                        options: [("", PalmiL10n.tr("ml.connection.custom"))] + ConnectionTemplateCatalog.all.map { ($0.id, $0.title) }
                    )
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
                            DraftModelScreen(item: $item, probe: probe) {
                                drafts.removeAll { $0.id == item.id }
                            }
                        } label: {
                            Text(item.title).lineLimit(1)
                        }
                    }
                    .onDelete { drafts.remove(atOffsets: $0) }
                    AddModelButtons(fetchDisabled: trimmedAddress.isEmpty, onFetch: { isFetching = true }, onManual: { isAddingManually = true })
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
            FetchModelsSheet(excludedIDs: Set(drafts.map(\.providerModelID)), defaultProtocol: defaultProtocol, probe: probe) { wireProtocol in
                var endpoints = try endpoints()
                endpoints.wireProtocolPreference = wireProtocol
                return try await ModelDiscovery.fetch(endpoints: endpoints, apiKey: apiKey)
            } onImport: { items in
                drafts.append(contentsOf: items)
            }
        }
        .sheet(isPresented: $isAddingManually) {
            ManualModelSheet(probe: probe) { drafts.append($0) }
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

/// “自动获取模型 / 手动添加模型”两个入口；添加分组与分组详情共用。
struct AddModelButtons: View {
    var fetchDisabled = false
    let onFetch: () -> Void
    let onManual: () -> Void

    var body: some View {
        Button(action: onFetch) {
            Label(PalmiL10n.tr("ml.add.fetch"), systemImage: "arrow.down.circle")
        }
        .disabled(fetchDisabled)
        Button(action: onManual) {
            Label(PalmiL10n.tr("ml.add.manual"), systemImage: "plus.circle")
        }
    }
}

/// 添加流程中的单个模型：与手动添加同一套内容，另有移除。
struct DraftModelScreen: View {
    @Binding var item: ModelDraftItem
    let probe: ModelProbe?
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            DraftModelForm(item: $item, probe: probe)
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

/// 手动添加：模型 ID、备注名称、协议、图片输入，可先检查再添加。
struct ManualModelSheet: View {
    let probe: ModelProbe?
    let onAdd: (ModelDraftItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var item = ModelDraftItem()

    var body: some View {
        NavigationStack {
            List {
                DraftModelForm(item: $item, probe: probe)
            }
            .listStyle(.insetGrouped)
            .navigationTitle(PalmiL10n.tr("ml.add.manual"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PalmiL10n.tr("ml.add.confirm")) {
                        item.providerModelID = item.providerModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                        onAdd(item)
                        dismiss()
                    }
                    .disabled(item.providerModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// 自动获取：先定协议与图片输入（批量）→ 获取 → 勾选（可全选）→ 可批量检查 → 导入。
struct FetchModelsSheet: View {
    let excludedIDs: Set<String>
    let defaultProtocol: LLMWireProtocolPreference
    let probe: ModelProbe?
    let discover: (LLMWireProtocolPreference) async throws -> [LLMDiscoveredModel]
    let onImport: ([ModelDraftItem]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var wireProtocol: LLMWireProtocolPreference = .automatic
    @State private var supportsVision = false
    @State private var models: [LLMDiscoveredModel] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = false
    @State private var connectivityResults: [String: Bool] = [:]
    @State private var visionResults: [String: Bool] = [:]
    @State private var connectivity: ModelCheckState = .idle
    @State private var vision: ModelCheckState = .idle
    @State private var errorMessage: String?
    @State private var loaded = false

    private var allSelected: Bool { !models.isEmpty && selected.count == models.count }

    var body: some View {
        NavigationStack {
            List {
                ModelSettingsBlock(wireProtocol: $wireProtocol, supportsVision: $supportsVision,
                                   footer: PalmiL10n.tr("ml.batch.footer"))

                Section {
                    Button {
                        Task { await load() }
                    } label: {
                        HStack {
                            Label(PalmiL10n.tr("ml.fetch.run"), systemImage: "arrow.down.circle")
                            if isLoading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isLoading)
                    Button {
                        selected = allSelected ? [] : Set(models.map(\.id))
                    } label: {
                        Label(PalmiL10n.tr(allSelected ? "ml.fetch.deselectAll" : "ml.fetch.selectAll"), systemImage: "checklist")
                    }
                    .disabled(models.isEmpty)
                }

                ModelChecksBlock(connectivity: connectivity, vision: vision, disabled: probe == nil || selected.isEmpty) {
                    await runChecks(vision: false)
                } onVision: {
                    await runChecks(vision: true)
                }

                if !models.isEmpty {
                    Section(PalmiL10n.tr("ml.connection.models")) {
                        ForEach(models, id: \.id) { model in
                            row(model)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(PalmiL10n.tr("ml.add.fetch"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PalmiL10n.tr("ml.add.import")) {
                        onImport(models.filter { selected.contains($0.id) }.map {
                            ModelDraftItem($0, wireProtocol: wireProtocol, supportsVision: supportsVision || visionResults[$0.id] == true)
                        })
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .modelLibraryErrorAlert($errorMessage)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                wireProtocol = defaultProtocol
            }
        }
    }

    private func row(_ model: LLMDiscoveredModel) -> some View {
        Button {
            if selected.contains(model.id) { selected.remove(model.id) } else { selected.insert(model.id) }
        } label: {
            HStack(spacing: 8) {
                Text(model.remoteDisplayName ?? model.id).foregroundStyle(.primary)
                Spacer()
                resultIcon("bolt.fill", connectivityResults[model.id])
                resultIcon("photo.fill", visionResults[model.id])
                Image(systemName: selected.contains(model.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(model.id) ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func resultIcon(_ symbol: String, _ passed: Bool?) -> some View {
        if let passed {
            Image(systemName: symbol).font(.footnote).foregroundStyle(passed ? Color.green : Color.red)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await discover(wireProtocol).filter { !excludedIDs.contains($0.id) }
            selected = selected.intersection(models.map(\.id))
            if models.isEmpty { errorMessage = PalmiL10n.tr("ml.model.discoveryEmpty") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 对勾选的模型逐个检查；视觉通过的模型导入时自动开启图片输入。
    private func runChecks(vision checksVision: Bool) async {
        guard let probe else { return }
        if checksVision { vision = .running } else { connectivity = .running }
        var failures: [String] = []
        var results: [Bool] = []
        for model in models where selected.contains(model.id) {
            do {
                let passed: Bool
                if checksVision {
                    passed = try await probe.checkVision(model.id, wireProtocol: wireProtocol)
                } else {
                    try await probe.checkConnectivity(model.id, wireProtocol: wireProtocol)
                    passed = true
                }
                results.append(passed)
                if checksVision { visionResults[model.id] = passed } else { connectivityResults[model.id] = passed }
            } catch {
                results.append(false)
                if checksVision { visionResults[model.id] = false } else { connectivityResults[model.id] = false }
                failures.append("\(model.id)：\(error.localizedDescription)")
            }
        }
        if checksVision { vision = .aggregate(results) } else { connectivity = .aggregate(results) }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
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
        let probe = ModelProbe(runtime: store.modelRuntime, connection: connection, apiKey: library.credentialRead(for: connection).value)
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
                    AddModelButtons(onFetch: { isFetching = true }, onManual: { isAddingManually = true })
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
            FetchModelsSheet(excludedIDs: Set(models.map(\.providerModelID)),
                             defaultProtocol: connection.endpoints.wireProtocolPreference, probe: probe) { wireProtocol in
                var endpoints = connection.endpoints
                endpoints.wireProtocolPreference = wireProtocol
                return try await ModelDiscovery.fetch(endpoints: endpoints, apiKey: library.credentialRead(for: connection).value)
            } onImport: { items in
                add(items.map(\.draft))
            }
        }
        .sheet(isPresented: $isAddingManually) {
            ManualModelSheet(probe: probe) { add([$0.draft]) }
        }
        .confirmationDialog(PalmiL10n.tr("ml.connection.deleteConfirm", connection.displayName), isPresented: $isDeleting, titleVisibility: .visible) {
            Button(PalmiL10n.tr("common.delete"), role: .destructive) {
                do { try library.deleteConnection(connectionID); dismiss() } catch { errorMessage = error.localizedDescription }
            }
        } message: {
            let references = library.references(toConnection: connectionID)
            if !references.isEmpty { Text(PalmiL10n.tr("ml.delete.references", references.joined(separator: PalmiL10n.tr("common.listSeparator")))) }
        }
    }

    private func add(_ drafts: [ModelDraft]) {
        do { try library.addModels(connectionID: connectionID, drafts: drafts) } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - 模型详情

/// 模型详情：与添加时同一套字段与检查；另有设为主模型、删除。
struct ModelDetailScreen: View {
    @Bindable var store: ManualLabStore
    let modelID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var providerModelID = ""
    @State private var loaded = false
    @State private var isDeleting = false
    @State private var connectivity: ModelCheckState = .idle
    @State private var vision: ModelCheckState = .idle
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
        let probe = ModelProbe(runtime: store.modelRuntime, connection: connection, apiKey: library.credentialRead(for: connection).value)
        return List {
            ModelFieldsSections(
                providerModelID: $providerModelID,
                providerIDEditable: !isOAuth,
                alias: $alias,
                aliasPrompt: model.remoteDisplayName ?? model.providerModelID,
                wireProtocol: isOAuth || model.imageGenerationOnly ? nil : Binding(
                    get: { model.wireProtocol(in: connection) },
                    set: { value in
                        do { try library.setModelWireProtocol(modelID, preference: value) }
                        catch { errorMessage = error.localizedDescription }
                    }
                ),
                supportsVision: Binding(
                    get: { model.capabilities.effectiveState(.visionInput, evidenceKey: evidenceKey) == .supported },
                    set: { setVision($0) }
                ),
                onCommit: saveNames
            )

            if !model.imageGenerationOnly {
                ModelChecksBlock(connectivity: connectivity, vision: vision) {
                    saveNames()
                    connectivity = .running
                    do { try await probe.checkConnectivity(model.providerModelID, wireProtocol: model.wireProtocol(in: connection)); connectivity = .passed }
                    catch { connectivity = .failed; errorMessage = error.localizedDescription }
                } onVision: {
                    saveNames()
                    vision = .running
                    do {
                        let passed = try await probe.checkVision(model.providerModelID, wireProtocol: model.wireProtocol(in: connection))
                        vision = passed ? .passed : .failed
                        if passed { setVision(true) }
                    } catch {
                        vision = .failed
                        errorMessage = error.localizedDescription
                    }
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
            if !references.isEmpty { Text(PalmiL10n.tr("ml.delete.references", references.joined(separator: PalmiL10n.tr("common.listSeparator")))) }
        }
    }

    private func setVision(_ value: Bool) {
        do { try library.setCapabilityDeclaration(modelID, kind: .visionInput, state: value ? .supported : .unsupported) }
        catch { errorMessage = error.localizedDescription }
    }

    private func saveNames() {
        guard loaded, let model = library.state.model(modelID) else { return }
        let trimmedID = providerModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedAlias != (model.userAlias ?? "") || trimmedID != model.providerModelID else { return }
        do { try library.updateModel(modelID, alias: trimmedAlias, providerModelID: trimmedID) }
        catch { errorMessage = error.localizedDescription }
    }
}

/// 冲突处理：新旧版本同时修改同一关键字段时保留双方的值，由用户决定。
struct ModelLibraryConflictsScreen: View {
    let library: ModelLibraryStore
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(library.state.conflicts) { conflict in
                Section(conflict.localizedFieldTitle) {
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
