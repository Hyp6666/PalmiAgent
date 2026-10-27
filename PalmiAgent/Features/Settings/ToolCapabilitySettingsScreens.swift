import SwiftUI

/// 工具配置：给可配置的工具选模型或服务。名称与工具管理里的工具名一致；能直接选的都在本页用菜单选。
struct ToolCapabilitiesScreen: View {
    @Bindable var store: ManualLabStore
    @State private var imageSettings = ImageGenerationConfigurationStore.shared
    @State private var account = ChatGPTAccountStore.shared
    @State private var isShowingCodexOAuth = false
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }

    /// 只列当前 Codex 账号下的生图模型。
    private var imageModels: [ModelRecord] {
        library.state.models.filter { model in
            model.imageGenerationOnly && account.account != nil
                && library.state.connection(model.connectionID)?.chatGPTAccount?.accountID == account.account?.accountID
        }
    }

    var body: some View {
        List {
            Section {
                ModelMenuRow(title: PalmiL10n.tr("tool.facade.vision"),
                             value: ModelLibraryPresentation.toolBindingTitle(library.state.toolBindings.vision, library: library),
                             icon: "eye") {
                    ModelLibraryMenuItems(library: library, followTitle: PalmiL10n.tr("ml.tool.followMain"),
                                          selectedID: library.state.toolBindings.vision.modelID) { id in
                        do { try library.setVisionBinding(id.map(ToolModelBinding.model) ?? .followMainModel) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }

            Section {
                NavigationLink { WebToolSettingsScreen(store: store, operation: .search) } label: {
                    row(icon: "magnifyingglass", title: PalmiL10n.tr("tool.facade.webSearch"), value: webTitle(.search))
                }
                NavigationLink { WebToolSettingsScreen(store: store, operation: .fetch) } label: {
                    row(icon: "doc.text.magnifyingglass", title: PalmiL10n.tr("tool.facade.fetch"), value: webTitle(.fetch))
                }
            }

            Section {
                ModelMenuRow(title: PalmiL10n.tr("image.generation"),
                             value: imageSettings.selectedModelID.flatMap { library.state.model($0)?.title } ?? PalmiL10n.tr("common.none"),
                             icon: "photo.badge.plus") {
                    ModelMenuItem(title: PalmiL10n.tr("common.none"), selected: imageSettings.selectedModelID == nil) {
                        imageSettings.selectedModelID = nil
                    }
                    Section(PalmiL10n.tr("ml.oauth.groups")) {
                        Menu {
                            ForEach(imageModels) { model in
                                ModelMenuItem(title: model.title, selected: imageSettings.selectedModelID == model.id) {
                                    imageSettings.selectedModelID = model.id
                                }
                            }
                            if account.account == nil {
                                Button(PalmiL10n.tr("chatgpt.signIn")) { isShowingCodexOAuth = true }
                            }
                        } label: {
                            if imageModels.contains(where: { $0.id == imageSettings.selectedModelID }) {
                                Label("Codex OAuth", systemImage: "checkmark")
                            } else {
                                Text("Codex OAuth")
                            }
                        }
                    }
                }
            }

            Section {
                NavigationLink { ToolAuthorizationSettingsScreen(store: store) } label: {
                    row(icon: "checkmark.shield", title: PalmiL10n.tr("tool.authorization.title"),
                        value: store.toolAuthorizationStore.mode.localizedTitle)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("ml.tool.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isShowingCodexOAuth) { ChatGPTOAuthScreen(library: library) }
        .modelLibraryErrorAlert($errorMessage)
    }

    private func row(icon: String, title: String, value: String) -> some View {
        LabeledContent {
            Text(value).lineLimit(1)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func webTitle(_ operation: WebOperation) -> String {
        let web = library.state.web
        let id = operation == .search ? web.defaultSearchBindingID : web.defaultFetchBindingID
        guard let id else { return PalmiL10n.tr("ml.web.local") }
        guard let binding = web.binding(id) else { return PalmiL10n.tr("ml.binding.invalid") }
        return WebServiceTitles.title(binding, library: library)
    }
}

/// 工具授权：授权方式；自动审核时再选审核模型（菜单）与审核规则。
struct ToolAuthorizationSettingsScreen: View {
    @Bindable var store: ManualLabStore
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }
    private var authorization: ToolAuthorizationStore { store.toolAuthorizationStore }

    var body: some View {
        List {
            Section {
                ForEach(ToolAuthorizationMode.userSelectableCases) { mode in
                    SelectionRow(title: mode.localizedTitle, selected: authorization.mode == mode) { authorization.setMode(mode) }
                }
            }

            if authorization.mode == .autoReview {
                Section {
                    ModelMenuRow(title: PalmiL10n.tr("ml.tool.review"),
                                 value: ModelLibraryPresentation.toolBindingTitle(library.state.toolBindings.permissionReview, library: library)) {
                        ModelLibraryMenuItems(library: library, followTitle: PalmiL10n.tr("ml.tool.followMain"),
                                              selectedID: library.state.toolBindings.permissionReview.modelID) { id in
                            do { try library.setPermissionReviewBinding(id.map(ToolModelBinding.model) ?? .followMainModel) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    NavigationLink {
                        AutoReviewPolicyScreen(authorization: authorization)
                    } label: {
                        LabeledContent(PalmiL10n.tr("tool.authorization.autoReviewPolicy.title"),
                                       value: PalmiL10n.tr(authorization.customAutoReviewPolicy.isEmpty ? "ml.review.policyDefault" : "ml.review.policyCustom"))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("tool.authorization.title"))
        .navigationBarTitleDisplayMode(.inline)
        .modelLibraryErrorAlert($errorMessage)
    }
}

private struct AutoReviewPolicyScreen: View {
    @Bindable var authorization: ToolAuthorizationStore

    var body: some View {
        TextEditor(text: Binding(
            get: { authorization.customAutoReviewPolicy },
            set: { authorization.setCustomAutoReviewPolicy($0) }
        ))
        .padding(.horizontal, 12)
        .overlay(alignment: .topLeading) {
            if authorization.customAutoReviewPolicy.isEmpty {
                Text(PalmiL10n.tr("tool.authorization.autoReviewPolicy.placeholder"))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(PalmiL10n.tr("tool.authorization.autoReviewPolicy.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 单选行：选中显示对勾。
struct SelectionRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
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

@MainActor
enum WebServiceTitles {
    /// 需要模型的服务显示模型名，独立接口显示接口名。
    static func title(_ binding: WebCapabilityBinding, library: ModelLibraryStore) -> String {
        let adapter = WebAdapterCatalog.descriptor(binding.adapterID)
        if adapter?.requiresModel == true, let modelID = binding.modelRecordID, let model = library.state.model(modelID) {
            return model.title
        }
        return adapter?.title ?? binding.adapterID
    }
}

/// 网页搜索 / 网页读取：本机或远端二选一。
/// 本机搜索可选搜索引擎；远端按“分组 → 接口 →（需要时）模型”逐级选，可改接口地址、检查连通性。
struct WebToolSettingsScreen: View {
    @Bindable var store: ManualLabStore
    let operation: WebOperation
    @State private var usesRemote = false
    @State private var localEngine = WebSearchProviderSettings.selectedProviderID()
    @State private var endpointDraft = ""
    @State private var isEditingEndpoint = false
    @State private var isVerifying = false
    @State private var verified: Bool?
    @State private var errorMessage: String?
    @State private var loaded = false

    private var library: ModelLibraryStore { store.modelLibrary }
    private var defaultID: UUID? {
        operation == .search ? library.state.web.defaultSearchBindingID : library.state.web.defaultFetchBindingID
    }
    private var current: WebCapabilityBinding? { library.state.web.binding(defaultID) }

    var body: some View {
        List {
            Section {
                SelectionRow(title: PalmiL10n.tr("ml.web.local"), selected: !usesRemote) { selectLocal() }
                SelectionRow(title: PalmiL10n.tr("ml.web.remote"), selected: usesRemote) { selectRemote() }
            }

            if !usesRemote, operation == .search {
                Section {
                    ChoiceMenuRow(
                        title: PalmiL10n.tr("searchConfiguration.local.title"),
                        selection: Binding(get: { localEngine }, set: { localEngine = $0; WebSearchProviderSettings.setSelectedProviderID($0) }),
                        options: WebSearchProviderID.allCases.map { ($0, $0.localizedTitleForUI) }
                    )
                }
            }

            if usesRemote {
                Section {
                    ModelMenuRow(title: PalmiL10n.tr("ml.web.service"),
                                 value: current.map { WebServiceTitles.title($0, library: library) } ?? PalmiL10n.tr("common.notSelected"),
                                 isProblem: current == nil) {
                        serviceMenu
                    }
                    if let current {
                        Button {
                            endpointDraft = (try? current.endpoint.resolvedURL().absoluteString) ?? ""
                            isEditingEndpoint = true
                        } label: {
                            LabeledContent(PalmiL10n.tr("ml.web.endpoint"), value: current.endpoint.displayValue)
                                .foregroundStyle(.primary)
                        }
                        checkButton(current.id)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr(operation == .search ? "tool.facade.webSearch" : "tool.facade.fetch"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(PalmiL10n.tr("ml.web.endpoint"), isPresented: $isEditingEndpoint) {
            TextField("https://", text: $endpointDraft)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {}
            Button(PalmiL10n.tr("common.save")) { saveEndpoint() }
        }
        .modelLibraryErrorAlert($errorMessage)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            usesRemote = defaultID != nil
        }
        .onChange(of: defaultID) { _, _ in verified = nil }
    }

    // MARK: 远端服务菜单：分组 → 接口 →（需要模型时）模型

    private var connections: [ConnectionRecord] {
        ModelLibraryPresentation.sortedConnections(library).filter { connection in
            !WebAdapterCatalog.dedicatedAdapters(for: operation, connection: connection).isEmpty || !genericOptions(connection).isEmpty
        }
    }

    @ViewBuilder
    private var serviceMenu: some View {
        ForEach(connections) { connection in
            Menu {
                ForEach(WebAdapterCatalog.dedicatedAdapters(for: operation, connection: connection)) { adapter in
                    if adapter.requiresModel {
                        Menu {
                            ForEach(models(of: connection)) { model in
                                ModelMenuItem(title: model.title, selected: isCurrent(connection, adapter, model)) {
                                    pick(connection, adapter, model)
                                }
                            }
                        } label: {
                            menuLabel(adapter.title, selected: isCurrent(connection, adapter, nil, anyModel: true))
                        }
                    } else {
                        ModelMenuItem(title: adapter.title, selected: isCurrent(connection, adapter, nil)) {
                            pick(connection, adapter, nil)
                        }
                    }
                }
                let generic = genericOptions(connection)
                ForEach(Array(Set(generic.map(\.adapter.id))).sorted(), id: \.self) { adapterID in
                    if let adapter = WebAdapterCatalog.descriptor(adapterID) {
                        Menu {
                            ForEach(generic.filter { $0.adapter.id == adapterID }.map(\.model)) { model in
                                ModelMenuItem(title: model.title, selected: isCurrent(connection, adapter, model)) {
                                    pick(connection, adapter, model)
                                }
                            }
                        } label: {
                            menuLabel(adapter.title, selected: isCurrent(connection, adapter, nil, anyModel: true))
                        }
                    }
                }
            } label: {
                menuLabel(connection.displayName, selected: current?.connectionID == connection.id)
            }
        }
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func models(of connection: ConnectionRecord) -> [ModelRecord] {
        library.state.models.filter { $0.connectionID == connection.id && !$0.imageGenerationOnly }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// 通用联网接口按模型协议适用；已由专用接口覆盖的分组不再重复列。
    private func genericOptions(_ connection: ConnectionRecord) -> [(model: ModelRecord, adapter: WebAdapterDescriptor)] {
        guard connection.chatGPTAccount == nil else { return [] }
        let dedicated = Set(WebAdapterCatalog.dedicatedAdapters(for: operation, connection: connection).map(\.id))
        return models(of: connection).compactMap { model in
            guard let adapter = WebAdapterCatalog.genericAdapter(for: operation, wireProtocol: model.wireProtocol(in: connection)),
                  !dedicated.contains(adapter.id) else { return nil }
            return (model, adapter)
        }
    }

    private func isCurrent(_ connection: ConnectionRecord, _ adapter: WebAdapterDescriptor, _ model: ModelRecord?, anyModel: Bool = false) -> Bool {
        guard let current, current.connectionID == connection.id, current.adapterID == adapter.id else { return false }
        if anyModel || !adapter.requiresModel { return true }
        return current.modelRecordID == model?.id
    }

    // MARK: 操作

    private func setDefault(_ id: UUID?) {
        do { try library.setDefaultWebBinding(id, for: operation) } catch { errorMessage = error.localizedDescription }
    }

    private func selectLocal() {
        usesRemote = false
        setDefault(nil)
    }

    /// 切到远端时沿用上次用过的远端配置；没有就等用户在菜单里选。
    private func selectRemote() {
        usesRemote = true
        guard defaultID == nil,
              let recent = library.state.web.bindings.filter({ $0.operation == operation }).max(by: { $0.updatedAt < $1.updatedAt }) else { return }
        setDefault(recent.id)
    }

    private func pick(_ connection: ConnectionRecord, _ adapter: WebAdapterDescriptor, _ model: ModelRecord?) {
        if let existing = library.state.web.bindings.first(where: { binding in
            binding.operation == operation && binding.connectionID == connection.id && binding.adapterID == adapter.id
                && (!adapter.requiresModel || binding.modelRecordID == model?.id)
        }) {
            setDefault(existing.id)
            return
        }
        guard let endpoint = WebAdapterCatalog.suggestedEndpoint(for: adapter, connection: connection) else {
            errorMessage = PalmiL10n.tr("ml.web.noEndpoint")
            return
        }
        let binding = WebCapabilityBinding(
            id: UUID(), operation: operation, adapterID: adapter.id, executionKind: adapter.executionKind,
            connectionID: connection.id, modelRecordID: adapter.requiresModel ? model?.id : nil, endpoint: endpoint,
            options: [:], revision: 1, userLabel: nil, createdAt: .now, updatedAt: .now
        )
        do {
            try library.upsertWebBinding(binding)
            try library.setDefaultWebBinding(binding.id, for: operation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveEndpoint() {
        guard var binding = current else { return }
        binding.endpoint = .explicitURL(endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        do { try library.upsertWebBinding(binding) } catch { errorMessage = error.localizedDescription }
        verified = nil
    }

    private func checkButton(_ bindingID: UUID) -> some View {
        Button {
            Task { await verify(bindingID) }
        } label: {
            HStack {
                Text(PalmiL10n.tr("ml.model.connectivity"))
                Spacer()
                if isVerifying {
                    ProgressView()
                } else if let verified {
                    Image(systemName: verified ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(verified ? Color.green : Color.red)
                }
            }
        }
        .disabled(isVerifying)
    }

    /// 检查结果只用于显示，不影响这项配置的使用。
    private func verify(_ bindingID: UUID) async {
        isVerifying = true
        defer { isVerifying = false }
        let result = await store.webCapabilityService.verify(bindingID: bindingID)
        let ok = [.completed, .completedEmpty].contains(result.status) && result.errors.isEmpty
        verified = ok
        if !ok {
            let message = result.errors.map(\.localizedDescription).joined(separator: "\n")
            errorMessage = message.isEmpty ? result.status.rawValue : message
        }
    }
}
