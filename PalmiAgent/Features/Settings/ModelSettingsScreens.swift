import SwiftUI

/// 模型设置入口：一个默认主模型 + 模型库（按连接分组）。没有方案、轻模型或多模态槽位。
struct ModelHubScreen: View {
    @Bindable var store: ManualLabStore
    @State private var isAddingConnection = false
    @State private var isShowingMigration = false

    private var library: ModelLibraryStore { store.modelLibrary }

    var body: some View {
        List {
            if !library.availability.isReady {
                Section {
                    ModelLibraryStatusLine(text: library.unavailableMessage, isProblem: true)
                }
            }

            Section {
                NavigationLink {
                    MainModelPickerScreen(library: library, scope: nil)
                } label: {
                    let status = ModelLibraryPresentation.mainModelStatus(library)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(PalmiL10n.tr("ml.mainModel"))
                            Spacer()
                            Text(status.title).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let detail = status.detail {
                            ModelLibraryStatusLine(text: detail, isProblem: status.isProblem)
                        }
                    }
                }
            } footer: {
                Text(PalmiL10n.tr("ml.mainModel.footer"))
            }

            if !library.state.conflicts.isEmpty {
                Section(PalmiL10n.tr("ml.conflicts.title")) {
                    NavigationLink {
                        ModelLibraryConflictsScreen(library: library)
                    } label: {
                        Label(PalmiL10n.tr("ml.conflicts.count", library.state.conflicts.count), systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                ForEach(library.state.connections.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) { connection in
                    NavigationLink {
                        ConnectionDetailScreen(store: store, connectionID: connection.id)
                    } label: {
                        ConnectionRow(connection: connection, library: library)
                    }
                }
                Button {
                    isAddingConnection = true
                } label: {
                    Label(PalmiL10n.tr("ml.connection.add"), systemImage: "plus.circle")
                }
                NavigationLink {
                    ChatGPTOAuthScreen(library: library)
                } label: {
                    Label {
                        Text("Codex OAuth")
                    } icon: {
                        Image("CodexOAuthLogo").renderingMode(.template).resizable().scaledToFit().frame(width: 18, height: 18)
                    }
                }
            } header: {
                Text(PalmiL10n.tr("ml.library.title"))
            } footer: {
                Text(PalmiL10n.tr("ml.library.footer"))
            }

            Section {
                if let receipt = library.state.migrationReceipt {
                    Button {
                        isShowingMigration = true
                    } label: {
                        Label(PalmiL10n.tr("ml.migration.review"), systemImage: "sparkles")
                    }
                    LabeledContent(PalmiL10n.tr("ml.migration.completedAt"), value: receipt.completedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let issue = library.compatibilityIssue {
                    ModelLibraryStatusLine(text: issue, isProblem: true)
                } else {
                    ModelLibraryStatusLine(text: PalmiL10n.tr("ml.compat.ok"), isProblem: false)
                }
                if !library.state.tombstones.isEmpty {
                    NavigationLink {
                        ModelLibraryDeletedItemsScreen(library: library)
                    } label: {
                        Label(PalmiL10n.tr("ml.deleted.title", library.state.tombstones.count), systemImage: "trash")
                    }
                }
            } header: {
                Text(PalmiL10n.tr("ml.compat.title"))
            } footer: {
                Text(PalmiL10n.tr("ml.compat.footer"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("settings.row.modelManagement"))
        .navigationBarTitleDisplayMode(.inline)
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
}

private struct ConnectionRow: View {
    let connection: ConnectionRecord
    let library: ModelLibraryStore

    var body: some View {
        let models = library.state.models.filter { $0.connectionID == connection.id }
        let credential = ModelLibraryPresentation.credentialStatus(connection, library: library)
        let blocked = !library.state.blockingConflicts(for: .connection(connection.id)).isEmpty
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(connection.displayName).lineLimit(1)
                if blocked { ModelLibraryBadge(text: PalmiL10n.tr("ml.badge.conflict"), tint: .orange) }
            }
            HStack(spacing: 6) {
                Text(PalmiL10n.tr("ml.connection.modelCount", models.count))
                Text("·")
                Text(ModelLibraryPresentation.protocolTitle(connection.endpoints.wireProtocolPreference))
                if credential.isProblem {
                    Text("·")
                    Text(credential.text).foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// 主模型选择：只列可作为主模型的记录；失效的选择保留原 ID 并显示问题，而不是悄悄换成别的模型。
struct MainModelPickerScreen: View {
    let library: ModelLibraryStore
    let scope: ModelLibraryScope?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var selectedID: UUID? {
        if let scope { return library.scopeBinding(scope).explicitModelID }
        return library.state.defaultMainModel.modelID
    }

    var body: some View {
        List {
            if scope != nil {
                Section {
                    row(title: PalmiL10n.tr("ml.followDefault"), selected: selectedID == nil) {
                        apply(nil)
                    }
                }
            }
            if let selectedID, library.state.model(selectedID) == nil {
                Section {
                    ModelLibraryStatusLine(text: PalmiL10n.tr("ml.binding.invalidDetail"), isProblem: true)
                }
            }
            ForEach(ModelLibraryPresentation.groups(library: library)) { group in
                Section(group.title) {
                    ForEach(group.models) { model in
                        let usable = !model.imageGenerationOnly
                        row(title: model.title, subtitle: usable ? nil : PalmiL10n.tr("ml.mainModel.notUsable"),
                            selected: selectedID == model.id) {
                            apply(model.id)
                        }
                        .disabled(!usable)
                    }
                }
            }
            if scope == nil {
                Section {
                    Button(PalmiL10n.tr("ml.mainModel.clear"), role: .destructive) { apply(nil) }
                        .disabled(selectedID == nil)
                } footer: {
                    Text(PalmiL10n.tr("ml.mainModel.clearFooter"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("ml.mainModel"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func row(title: String, subtitle: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func apply(_ id: UUID?) {
        do {
            if let scope {
                try library.setScopeBinding(id.map(ScopedMainModelBinding.explicitModel) ?? .inherit, scope: scope)
            } else {
                try library.setDefaultMainModel(id)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 添加或编辑连接：预设填好成对的地址与协议；名字是可选备注，不是身份。
struct ConnectionEditorScreen: View {
    @Bindable var store: ManualLabStore
    let connectionID: UUID?
    @Environment(\.dismiss) private var dismiss

    @State private var templateID: String = ""
    @State private var label = ""
    @State private var address = ""
    @State private var preference: LLMWireProtocolPreference = .automatic
    @State private var apiKey = ""
    @State private var showsKey = false
    @State private var clearKey = false
    @State private var sendsBearer = false
    @State private var geminiBase = ""
    @State private var discovered: [LLMDiscoveredModel] = []
    @State private var selectedModelIDs: Set<String> = []
    @State private var manualModelID = ""
    @State private var isDiscovering = false
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var isShowingAddressHelp = false

    private var library: ModelLibraryStore { store.modelLibrary }
    private var existing: ConnectionRecord? { connectionID.flatMap { library.state.connection($0) } }
    private var template: ConnectionTemplate? { ConnectionTemplateCatalog.template(templateID.isEmpty ? nil : templateID) }

    var body: some View {
        Form {
            if connectionID == nil {
                Section {
                    Picker(PalmiL10n.tr("ml.connection.preset"), selection: $templateID) {
                        Text(PalmiL10n.tr("ml.connection.custom")).tag("")
                        ForEach(ConnectionTemplateCatalog.all) { Text($0.title).tag($0.id) }
                    }
                    .onChange(of: templateID) { _, _ in applyTemplate() }
                } footer: {
                    if let template { Text(template.note) }
                }
            }

            Section {
                TextField(PalmiL10n.tr("ml.connection.labelPlaceholder"), text: $label)
            } header: {
                Text(PalmiL10n.tr("ml.connection.label"))
            } footer: {
                Text(PalmiL10n.tr("ml.connection.labelFooter"))
            }

            Section {
                TextField("https://api.example.com/v1", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker(PalmiL10n.tr("model.connection.protocol.title"), selection: $preference) {
                    ForEach(LLMWireProtocolPreference.allCases) { Text(ModelLibraryPresentation.protocolTitle($0)).tag($0) }
                }
            } header: {
                HStack {
                    Text(PalmiL10n.tr("model.connection.compatibleAddress"))
                    Spacer()
                    Button { isShowingAddressHelp = true } label: { Image(systemName: "questionmark.circle") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            } footer: {
                Text(template == nil ? PalmiL10n.tr("ml.connection.addressFooter") : PalmiL10n.tr("ml.connection.presetFooter"))
            }

            Section {
                HStack {
                    Group {
                        if showsKey { TextField(PalmiL10n.tr("model.apiKey.placeholder"), text: $apiKey) }
                        else { SecureField(existing == nil ? PalmiL10n.tr("model.apiKey.placeholder") : PalmiL10n.tr("ml.connection.keyKeep"), text: $apiKey) }
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    Button { showsKey.toggle() } label: { Image(systemName: showsKey ? "eye.slash" : "eye") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                if let existing, existing.credentialReference != nil {
                    Toggle(PalmiL10n.tr("ml.connection.clearKey"), isOn: $clearKey)
                }
            } header: {
                Text(PalmiL10n.tr("model.field.apiKey"))
            } footer: {
                Text(PalmiL10n.tr("ml.connection.keyFooter"))
            }

            Section(PalmiL10n.tr("model.connection.advanced")) {
                if preference == .anthropicMessages || preference == .automatic {
                    Toggle(PalmiL10n.tr("ml.connection.messagesBearer"), isOn: $sendsBearer)
                }
                TextField(PalmiL10n.tr("ml.connection.geminiNative"), text: $geminiBase)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }

            if connectionID == nil {
                Section {
                    Button {
                        Task { await discover() }
                    } label: {
                        HStack {
                            Label(PalmiL10n.tr("model.discovery.fetch"), systemImage: "arrow.clockwise")
                            if isDiscovering { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDiscovering)
                    ForEach(discovered, id: \.id) { model in
                        Button {
                            if selectedModelIDs.contains(model.id) { selectedModelIDs.remove(model.id) } else { selectedModelIDs.insert(model.id) }
                        } label: {
                            HStack {
                                Text(model.remoteDisplayName ?? model.id).foregroundStyle(.primary)
                                Spacer()
                                if selectedModelIDs.contains(model.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                    HStack {
                        TextField(PalmiL10n.tr("ml.model.manualPlaceholder"), text: $manualModelID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(PalmiL10n.tr("ml.model.addManual")) {
                            let id = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !id.isEmpty else { return }
                            if !discovered.contains(where: { $0.id == id }) {
                                discovered.append(LLMDiscoveredModel(id: id, ownedBy: nil))
                            }
                            selectedModelIDs.insert(id)
                            manualModelID = ""
                        }
                        .disabled(manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text(PalmiL10n.tr("ml.connection.models"))
                } footer: {
                    Text(PalmiL10n.tr("ml.connection.modelsFooter"))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(PalmiL10n.tr(connectionID == nil ? "ml.connection.add" : "ml.connection.edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("common.cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(PalmiL10n.tr("common.save")) { save() }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(isPresented: $isShowingAddressHelp) {
            NavigationStack { ModelAddressHelpScreen(languageID: PalmiLanguage.current.rawValue) }
        }
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let existing else { return }
        label = existing.userLabel ?? ""
        address = existing.endpoints.inputAddress
        preference = existing.endpoints.wireProtocolPreference
        sendsBearer = existing.endpoints.messagesSendsBearer ?? false
        geminiBase = existing.endpoints.geminiNativeBaseURL ?? ""
        templateID = existing.templateID ?? ""
    }

    private func applyTemplate() {
        guard let template else { return }
        address = template.apiBase
        preference = template.protocolPreference
        geminiBase = template.geminiNativeBaseURL ?? ""
        sendsBearer = false
    }

    private func endpoints() throws -> ConnectionEndpointConfiguration {
        var endpoints: ConnectionEndpointConfiguration
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let template, trimmed == template.apiBase, preference == template.protocolPreference {
            endpoints = template.endpoints()
        } else if let existing, trimmed == existing.endpoints.inputAddress, preference == existing.endpoints.wireProtocolPreference {
            endpoints = existing.endpoints
        } else {
            endpoints = try ModelLibraryStore.endpoints(forCustomAddress: trimmed, preference: preference)
        }
        endpoints.messagesSendsBearer = sendsBearer ? true : (existing == nil ? nil : false)
        let gemini = geminiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoints.geminiNativeBaseURL = gemini.isEmpty ? nil : gemini
        return endpoints
    }

    private func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let endpoints = try endpoints()
            let service = LLMModelDiscoveryService()
            let result: LLMModelDiscoveryResult
            if let modelsURL = endpoints.modelsURL.flatMap(URL.init(string:)) {
                result = try await service.fetchModels(modelsURL: modelsURL, apiKey: apiKey, wireProtocol: preference.explicitWireProtocol)
            } else {
                result = try await service.fetchModels(inputAddress: address, apiKey: apiKey, protocolPreference: preference)
            }
            discovered = result.models
            if result.models.isEmpty { errorMessage = PalmiL10n.tr("ml.model.discoveryEmpty") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            let endpoints = try endpoints()
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if let connectionID {
                try library.updateConnection(
                    connectionID,
                    label: .some(trimmedLabel.isEmpty ? nil : label),
                    endpoints: endpoints,
                    newAPIKey: apiKey.isEmpty ? nil : apiKey,
                    clearAPIKey: clearKey && apiKey.isEmpty
                )
            } else {
                let id = try library.addConnection(ConnectionDraft(
                    userLabel: trimmedLabel.isEmpty ? nil : label,
                    templateID: template?.id,
                    endpoints: endpoints,
                    apiKey: apiKey
                ))
                let drafts = discovered.filter { selectedModelIDs.contains($0.id) }.map {
                    ModelDraft(providerModelID: $0.id, userAlias: nil, remoteDisplayName: $0.remoteDisplayName,
                               canonicalID: $0.canonicalID, ownedBy: $0.ownedBy)
                }
                if !drafts.isEmpty { try library.addModels(connectionID: id, drafts: drafts) }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 连接详情：凭据状态、模型列表、发现与手动添加、编辑与删除。
struct ConnectionDetailScreen: View {
    @Bindable var store: ManualLabStore
    let connectionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var isDeleting = false
    @State private var discovered: [LLMDiscoveredModel] = []
    @State private var isDiscovering = false
    @State private var manualModelID = ""
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
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func content(_ connection: ConnectionRecord) -> some View {
        let models = library.state.models.filter { $0.connectionID == connection.id }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let credential = ModelLibraryPresentation.credentialStatus(connection, library: library)
        List {
            Section {
                LabeledContent(PalmiL10n.tr("ml.connection.label"), value: connection.userLabel ?? PalmiL10n.tr("ml.connection.unlabeled"))
                LabeledContent(PalmiL10n.tr("model.connection.compatibleAddress"), value: ModelLibraryURLDisplay.safeDisplay(connection.endpoints.inputAddress))
                LabeledContent(PalmiL10n.tr("model.connection.protocol.title"), value: ModelLibraryPresentation.protocolTitle(connection.endpoints.wireProtocolPreference))
                LabeledContent(PalmiL10n.tr("model.field.apiKey")) {
                    Text(credential.text).foregroundStyle(credential.isProblem ? .orange : .secondary)
                }
                Button(PalmiL10n.tr("ml.connection.edit")) { isEditing = true }
                    .disabled(connection.chatGPTAccount != nil)
            }

            Section {
                ForEach(models) { model in
                    NavigationLink {
                        ModelDetailScreen(store: store, modelID: model.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.title)
                            HStack(spacing: 4) {
                                if model.title != model.providerModelID {
                                    Text(model.providerModelID).font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(ModelLibraryPresentation.usageBadges(model, library: library), id: \.self) { ModelLibraryBadge(text: $0) }
                            }
                        }
                    }
                }
                if connection.chatGPTAccount == nil {
                    Button {
                        Task { await discover(connection) }
                    } label: {
                        HStack {
                            Label(PalmiL10n.tr("model.discovery.fetch"), systemImage: "arrow.clockwise")
                            if isDiscovering { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isDiscovering)
                    ForEach(discovered.filter { item in !models.contains { $0.providerModelID == item.id } }, id: \.id) { item in
                        Button {
                            add([ModelDraft(providerModelID: item.id, userAlias: nil, remoteDisplayName: item.remoteDisplayName,
                                            canonicalID: item.canonicalID, ownedBy: item.ownedBy)])
                        } label: {
                            Label(item.remoteDisplayName ?? item.id, systemImage: "plus")
                        }
                    }
                    HStack {
                        TextField(PalmiL10n.tr("ml.model.manualPlaceholder"), text: $manualModelID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(PalmiL10n.tr("ml.model.addManual")) {
                            add([ModelDraft(providerModelID: manualModelID, userAlias: nil)])
                            manualModelID = ""
                        }
                        .disabled(manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } header: {
                Text(PalmiL10n.tr("ml.connection.models"))
            } footer: {
                Text(PalmiL10n.tr("ml.connection.discoveryFooter"))
            }

            Section {
                Button(PalmiL10n.tr("ml.connection.delete"), role: .destructive) { isDeleting = true }
            } footer: {
                Text(PalmiL10n.tr("ml.connection.deleteFooter"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(connection.displayName)
        .confirmationDialog(PalmiL10n.tr("ml.connection.delete"), isPresented: $isDeleting, titleVisibility: .visible) {
            Button(PalmiL10n.tr("ml.connection.delete"), role: .destructive) {
                do { try library.deleteConnection(connectionID); dismiss() } catch { errorMessage = error.localizedDescription }
            }
        } message: {
            let references = library.references(toConnection: connectionID)
            Text(references.isEmpty ? PalmiL10n.tr("ml.delete.noReferences") : PalmiL10n.tr("ml.delete.references", references.joined(separator: "、")))
        }
    }

    private func discover(_ connection: ConnectionRecord) async {
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            let key = library.credentialRead(for: connection).value
            let service = LLMModelDiscoveryService()
            let result: LLMModelDiscoveryResult
            if let modelsURL = connection.endpoints.modelsURL.flatMap(URL.init(string:)) {
                result = try await service.fetchModels(modelsURL: modelsURL, apiKey: key, wireProtocol: connection.endpoints.wireProtocolPreference.explicitWireProtocol)
            } else {
                result = try await service.fetchModels(inputAddress: connection.endpoints.inputAddress, apiKey: key, protocolPreference: connection.endpoints.wireProtocolPreference)
            }
            discovered = result.models
            if result.models.isEmpty { errorMessage = PalmiL10n.tr("ml.model.discoveryEmpty") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ drafts: [ModelDraft]) {
        do { try library.addModels(connectionID: connectionID, drafts: drafts) } catch { errorMessage = error.localizedDescription }
    }
}

/// 模型详情：别名、远端标识、能力声明与证据、连通性检查（不是能力验证）、设为主模型、删除。
struct ModelDetailScreen: View {
    @Bindable var store: ManualLabStore
    let modelID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var providerModelID = ""
    @State private var loaded = false
    @State private var isDeleting = false
    @State private var checkState: String?
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
        .navigationBarTitleDisplayMode(.inline)
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func content(_ model: ModelRecord, _ connection: ConnectionRecord) -> some View {
        let evidenceKey = ModelLibraryStore.evidenceKey(model: model, connection: connection)
        List {
            Section {
                TextField(PalmiL10n.tr("ml.model.aliasPlaceholder"), text: $alias)
                TextField(PalmiL10n.tr("ml.model.providerID"), text: $providerModelID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
                Button(PalmiL10n.tr("common.save")) {
                    do { try library.updateModel(modelID, alias: alias, providerModelID: providerModelID) }
                    catch { errorMessage = error.localizedDescription }
                }
                .disabled(alias == (model.userAlias ?? "") && providerModelID == model.providerModelID)
            } header: {
                Text(connection.displayName)
            } footer: {
                Text(PalmiL10n.tr("ml.model.providerIDFooter"))
            }

            Section {
                ForEach(ModelCapabilityKind.allCases, id: \.self) { kind in
                    let declared = model.capabilities.declarations[kind]
                    let effective = model.capabilities.effectiveState(kind, evidenceKey: evidenceKey)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(ModelLibraryPresentation.capabilityTitle(kind), selection: Binding<ModelCapabilityState?>(
                            get: { declared?.state },
                            set: { value in
                                do { try library.setCapabilityDeclaration(modelID, kind: kind, state: value) }
                                catch { errorMessage = error.localizedDescription }
                            }
                        )) {
                            Text(PalmiL10n.tr("ml.capability.undeclared")).tag(Optional<ModelCapabilityState>.none)
                            Text(PalmiL10n.tr("ml.capability.supported")).tag(Optional(ModelCapabilityState.supported))
                            Text(PalmiL10n.tr("ml.capability.unsupported")).tag(Optional(ModelCapabilityState.unsupported))
                        }
                        Text(PalmiL10n.tr("ml.capability.effective", ModelLibraryPresentation.stateTitle(effective),
                                          ModelLibraryPresentation.sourceTitle(model.capabilities.source(kind, evidenceKey: evidenceKey))))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(PalmiL10n.tr("ml.capability.title"))
            } footer: {
                Text(PalmiL10n.tr("ml.capability.footer"))
            }

            Section {
                Button {
                    Task { await checkConnectivity() }
                } label: {
                    HStack {
                        Label(PalmiL10n.tr("ml.model.connectivity"), systemImage: "bolt.horizontal")
                        if isChecking { Spacer(); ProgressView() }
                    }
                }
                .disabled(isChecking || model.imageGenerationOnly)
                if let checkState { Text(checkState).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text(PalmiL10n.tr("ml.model.connectivityFooter"))
            }

            Section {
                Button(PalmiL10n.tr("ml.model.setMain")) {
                    do { try library.setDefaultMainModel(modelID) } catch { errorMessage = error.localizedDescription }
                }
                .disabled(model.imageGenerationOnly || library.state.defaultMainModel.modelID == modelID)
                Button(PalmiL10n.tr("ml.model.delete"), role: .destructive) { isDeleting = true }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(model.title)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            alias = model.userAlias ?? ""
            providerModelID = model.providerModelID
        }
        .confirmationDialog(PalmiL10n.tr("ml.model.delete"), isPresented: $isDeleting, titleVisibility: .visible) {
            Button(PalmiL10n.tr("ml.model.delete"), role: .destructive) {
                do { try library.deleteModel(modelID); dismiss() } catch { errorMessage = error.localizedDescription }
            }
        } message: {
            let references = library.references(toModel: modelID)
            Text(references.isEmpty ? PalmiL10n.tr("ml.delete.noReferences") : PalmiL10n.tr("ml.delete.references", references.joined(separator: "、")))
        }
    }

    /// 普通连通性只证明能连通与鉴权；不验证看图、工具或联网等任何能力。
    private func checkConnectivity() async {
        isChecking = true
        defer { isChecking = false }
        switch library.resolveModel(modelID, asMainModel: false) {
        case .failure(let issue):
            checkState = issue.localizedDescription
        case .success(let resolved):
            do {
                let response = try await store.modelRuntime.complete(AgentModelRequest(
                    selection: AgentModelSelection(providerID: .customOpenAI, modelRole: .reasoningModel, reasoning: .disabled,
                                                   configurationOverride: .resolved(resolved.configuration)),
                    apiMessages: [.user("Reply with OK only.")],
                    tools: [], toolIntent: .none
                ))
                let text = response.message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                checkState = PalmiL10n.tr("ml.model.connectivityOK", String(text.prefix(40)))
            } catch {
                checkState = error.localizedDescription
            }
        }
    }
}

/// 冲突处理：新旧版本同时修改同一关键字段时保留双方证据，由用户决定。
struct ModelLibraryConflictsScreen: View {
    let library: ModelLibraryStore
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(library.state.conflicts) { conflict in
                Section {
                    LabeledContent(PalmiL10n.tr("ml.conflicts.field"), value: conflict.field)
                    LabeledContent(PalmiL10n.tr("ml.conflicts.current"), value: conflict.currentValue ?? "—")
                    LabeledContent(PalmiL10n.tr("ml.conflicts.legacy"), value: conflict.legacyValue ?? PalmiL10n.tr("ml.conflicts.deleted"))
                    LabeledContent(PalmiL10n.tr("ml.conflicts.base"), value: conflict.baseValue ?? "—")
                    if let alternate = conflict.alternateBaseValue {
                        LabeledContent(PalmiL10n.tr("ml.conflicts.alternateBase"), value: alternate)
                    }
                    Button(PalmiL10n.tr("ml.conflicts.keepCurrent")) { resolve(conflict, keepCurrent: true) }
                    Button(PalmiL10n.tr("ml.conflicts.useLegacy")) { resolve(conflict, keepCurrent: false) }
                } footer: {
                    if conflict.blocksExecution { Text(PalmiL10n.tr("ml.conflicts.blocking")) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("ml.conflicts.title"))
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func resolve(_ conflict: ModelLibraryConflict, keepCurrent: Bool) {
        do { try library.resolveConflict(conflict.id, keepCurrent: keepCurrent) } catch { errorMessage = error.localizedDescription }
    }
}

/// 已删除的连接与模型：恢复是显式命令，沿用原 UUID。
struct ModelLibraryDeletedItemsScreen: View {
    let library: ModelLibraryStore
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(library.state.tombstones) { tombstone in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(tombstone))
                        Text(PalmiL10n.tr(tombstone.deletedBy == "legacy" ? "ml.deleted.byLegacy" : "ml.deleted.byUser"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(PalmiL10n.tr("ml.deleted.restore")) {
                        do { try library.restoreTombstone(tombstone.id) } catch { errorMessage = error.localizedDescription }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("ml.deleted.screenTitle"))
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func title(_ tombstone: ModelLibraryTombstone) -> String {
        switch tombstone.kind {
        case .model: (try? JSONDecoder().decode(ModelRecord.self, from: tombstone.snapshot))?.title ?? tombstone.id.uuidString
        case .connection: (try? JSONDecoder().decode(ConnectionRecord.self, from: tombstone.snapshot))?.displayName ?? tombstone.id.uuidString
        }
    }
}
