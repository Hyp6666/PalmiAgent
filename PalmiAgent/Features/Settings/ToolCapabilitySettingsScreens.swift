import SwiftUI

/// 工具配置：给可配置的工具选模型或服务。名称与工具管理里的工具名一致。
struct ToolCapabilitiesScreen: View {
    @Bindable var store: ManualLabStore
    @State private var imageSettings = ImageGenerationConfigurationStore.shared

    private var library: ModelLibraryStore { store.modelLibrary }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ModelLibraryPickerScreen(
                        library: library,
                        title: PalmiL10n.tr("tool.facade.vision"),
                        followTitle: PalmiL10n.tr("ml.tool.followMain"),
                        selectedID: library.state.toolBindings.vision.modelID,
                        onSelect: { try library.setVisionBinding($0.map(ToolModelBinding.model) ?? .followMainModel) }
                    )
                } label: {
                    row(icon: "eye", title: PalmiL10n.tr("tool.facade.vision"),
                        value: ModelLibraryPresentation.toolBindingTitle(library.state.toolBindings.vision, library: library))
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
                NavigationLink { ImageGenerationConfigurationScreen(library: library) } label: {
                    row(icon: "photo.badge.plus", title: PalmiL10n.tr("image.generation"),
                        value: imageSettings.selectedModelID.flatMap { library.state.model($0)?.title } ?? PalmiL10n.tr("common.notSelected"))
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
        if let modelID = binding.modelRecordID, let model = library.state.model(modelID) { return model.title }
        return library.state.connection(binding.connectionID)?.displayName ?? PalmiL10n.tr("ml.binding.invalid")
    }
}

/// 工具授权：授权方式；自动审核时再选审核模型与审核规则。
struct ToolAuthorizationSettingsScreen: View {
    @Bindable var store: ManualLabStore

    private var library: ModelLibraryStore { store.modelLibrary }
    private var authorization: ToolAuthorizationStore { store.toolAuthorizationStore }

    var body: some View {
        List {
            Section {
                ForEach(ToolAuthorizationMode.userSelectableCases) { mode in
                    Button { authorization.setMode(mode) } label: {
                        HStack {
                            Text(mode.localizedTitle).foregroundStyle(.primary)
                            Spacer()
                            if authorization.mode == mode { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if authorization.mode == .autoReview {
                Section {
                    NavigationLink {
                        ModelLibraryPickerScreen(
                            library: library,
                            title: PalmiL10n.tr("ml.tool.review"),
                            followTitle: PalmiL10n.tr("ml.tool.followMain"),
                            selectedID: library.state.toolBindings.permissionReview.modelID,
                            onSelect: { try library.setPermissionReviewBinding($0.map(ToolModelBinding.model) ?? .followMainModel) }
                        )
                    } label: {
                        LabeledContent(PalmiL10n.tr("ml.tool.review"),
                                       value: ModelLibraryPresentation.toolBindingTitle(library.state.toolBindings.permissionReview, library: library))
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

/// 网页搜索 / 网页读取：本机，或模型库里的一个模型。选中云端模型后可以换接口、检查可用性。
struct WebToolSettingsScreen: View {
    @Bindable var store: ManualLabStore
    let operation: WebOperation
    @State private var isVerifying = false
    @State private var verified: Bool?
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }
    private var defaultID: UUID? {
        operation == .search ? library.state.web.defaultSearchBindingID : library.state.web.defaultFetchBindingID
    }
    private var current: WebCapabilityBinding? { library.state.web.binding(defaultID) }

    /// 只列出有可用接口的模型。
    private var groups: [ModelLibraryPresentation.Group] {
        let models = library.state.models.filter { model in
            guard let connection = library.state.connection(model.connectionID) else { return false }
            return !WebAdapterCatalog.adapters(for: operation, model: model, connection: connection).isEmpty
        }
        return ModelLibraryPresentation.groups(library: library, models: models)
    }

    var body: some View {
        List {
            Section {
                choice(PalmiL10n.tr("ml.web.local"), selected: defaultID == nil) { setDefault(nil) }
            }

            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.models) { model in
                        choice(model.title, selected: isSelected(model, in: group)) { select(model) }
                    }
                }
            }

            if let current {
                currentSection(current)
            } else if operation == .search {
                Section {
                    NavigationLink { WebSearchProviderSettingsScreen() } label: {
                        Text(PalmiL10n.tr("searchConfiguration.local.title"))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr(operation == .search ? "tool.facade.webSearch" : "tool.facade.fetch"))
        .navigationBarTitleDisplayMode(.inline)
        .modelLibraryErrorAlert($errorMessage)
        .onChange(of: defaultID) { _, _ in verified = nil }
    }

    @ViewBuilder
    private func currentSection(_ binding: WebCapabilityBinding) -> some View {
        let adapters = availableAdapters(for: binding)
        Section {
            if adapters.count > 1 {
                Picker(PalmiL10n.tr("ml.web.adapter"), selection: Binding(
                    get: { binding.adapterID },
                    set: { changeAdapter(of: binding, to: $0) }
                )) {
                    ForEach(adapters) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.menu)
            }
            Button {
                Task { await verify(binding.id) }
            } label: {
                HStack {
                    Text(PalmiL10n.tr("ml.web.verify"))
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

    /// 旧的独立接口配置没有记录模型时，选中标记落在该来源的第一个模型上。
    private func isSelected(_ model: ModelRecord, in group: ModelLibraryPresentation.Group) -> Bool {
        guard let current else { return false }
        if let modelID = current.modelRecordID { return modelID == model.id }
        return current.connectionID == model.connectionID && group.models.first?.id == model.id
    }

    private func availableAdapters(for binding: WebCapabilityBinding) -> [WebAdapterDescriptor] {
        var adapters: [WebAdapterDescriptor] = []
        if let modelID = binding.modelRecordID, let model = library.state.model(modelID),
           let connection = library.state.connection(model.connectionID) {
            adapters = WebAdapterCatalog.adapters(for: operation, model: model, connection: connection)
        }
        if !adapters.contains(where: { $0.id == binding.adapterID }), let own = WebAdapterCatalog.descriptor(binding.adapterID) {
            adapters.insert(own, at: 0)
        }
        return adapters
    }

    private func setDefault(_ id: UUID?) {
        do { try library.setDefaultWebBinding(id, for: operation) } catch { errorMessage = error.localizedDescription }
    }

    private func select(_ model: ModelRecord) {
        if let existing = library.state.web.bindings.first(where: { $0.operation == operation && $0.modelRecordID == model.id }) {
            setDefault(existing.id)
            return
        }
        guard let connection = library.state.connection(model.connectionID),
              let descriptor = WebAdapterCatalog.adapters(for: operation, model: model, connection: connection).first,
              let endpoint = WebAdapterCatalog.suggestedEndpoint(for: descriptor, connection: connection) else { return }
        let binding = WebCapabilityBinding(
            id: UUID(), operation: operation, adapterID: descriptor.id, executionKind: descriptor.executionKind,
            connectionID: connection.id, modelRecordID: model.id, endpoint: endpoint, options: [:], revision: 1,
            userLabel: nil, createdAt: .now, updatedAt: .now
        )
        do {
            try library.upsertWebBinding(binding)
            try library.setDefaultWebBinding(binding.id, for: operation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func changeAdapter(of binding: WebCapabilityBinding, to adapterID: String) {
        guard adapterID != binding.adapterID, let descriptor = WebAdapterCatalog.descriptor(adapterID),
              let connection = library.state.connection(binding.connectionID),
              let endpoint = WebAdapterCatalog.suggestedEndpoint(for: descriptor, connection: connection) else { return }
        var updated = binding
        updated.adapterID = descriptor.id
        updated.executionKind = descriptor.executionKind
        updated.endpoint = endpoint
        updated.options = [:]
        do { try library.upsertWebBinding(updated) } catch { errorMessage = error.localizedDescription }
        verified = nil
    }

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
