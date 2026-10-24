import SwiftUI

/// 工具能力：看图、权限与自动审核、网页搜索、网页抓取、图片生成。每项说明它用哪个模型或连接、数据去向哪里。
struct ToolCapabilitiesScreen: View {
    @Bindable var store: ManualLabStore

    private var library: ModelLibraryStore { store.modelLibrary }

    var body: some View {
        List {
            Section {
                NavigationLink { VisionSettingsScreen(store: store) } label: {
                    capabilityRow(icon: "eye", title: PalmiL10n.tr("ml.tool.vision"), value: toolBindingTitle(library.state.toolBindings.vision))
                }
                NavigationLink { PermissionReviewSettingsScreen(store: store) } label: {
                    capabilityRow(icon: "checkmark.shield", title: PalmiL10n.tr("tool.authorization.title"),
                                  value: store.toolAuthorizationStore.mode.title)
                }
            } footer: {
                Text(PalmiL10n.tr("ml.tool.modelsFooter"))
            }

            Section {
                NavigationLink { WebCapabilitySettingsScreen(store: store, operation: .search) } label: {
                    capabilityRow(icon: "magnifyingglass", title: PalmiL10n.tr("ml.web.search"), value: webTitle(.search))
                }
                NavigationLink { WebCapabilitySettingsScreen(store: store, operation: .fetch) } label: {
                    capabilityRow(icon: "doc.text.magnifyingglass", title: PalmiL10n.tr("ml.web.fetch"), value: webTitle(.fetch))
                }
            } footer: {
                Text(PalmiL10n.tr("ml.web.footer"))
            }

            Section {
                NavigationLink { ImageGenerationConfigurationScreen(library: library) } label: {
                    capabilityRow(icon: "photo.badge.plus", title: PalmiL10n.tr("image.configuration"), value: "")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("ml.tool.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func capabilityRow(icon: String, title: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func toolBindingTitle(_ binding: ToolModelBinding) -> String {
        switch binding {
        case .followMainModel: PalmiL10n.tr("ml.tool.followMain")
        case .model(let id): library.state.model(id)?.title ?? PalmiL10n.tr("ml.binding.invalid")
        }
    }

    private func webTitle(_ operation: WebOperation) -> String {
        let web = library.state.web
        let id = operation == .search ? web.defaultSearchBindingID : web.defaultFetchBindingID
        guard let id else { return PalmiL10n.tr("ml.web.local") }
        return web.binding(id)?.userLabel ?? web.binding(id).flatMap { WebAdapterCatalog.descriptor($0.adapterID)?.title } ?? PalmiL10n.tr("ml.binding.invalid")
    }
}

/// 工具模型绑定选择：跟随本次主模型，或直接引用模型库中的一个模型。
struct ToolModelBindingPicker: View {
    let library: ModelLibraryStore
    let binding: ToolModelBinding
    let requireVision: Bool
    let onChange: (ToolModelBinding) -> Void

    var body: some View {
        Picker(PalmiL10n.tr("ml.tool.model"), selection: Binding<UUID?>(
            get: { binding.modelID },
            set: { onChange($0.map(ToolModelBinding.model) ?? .followMainModel) }
        )) {
            Text(PalmiL10n.tr("ml.tool.followMain")).tag(Optional<UUID>.none)
            ForEach(library.state.models.filter { !$0.imageGenerationOnly }) { model in
                Text(ModelLibraryPresentation.modelTitle(model, library: library)).tag(Optional(model.id))
            }
            if let id = binding.modelID, library.state.model(id) == nil {
                Text(PalmiL10n.tr("ml.binding.invalid")).tag(Optional(id))
            }
        }
        .pickerStyle(.navigationLink)
    }
}

struct VisionSettingsScreen: View {
    @Bindable var store: ManualLabStore
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }

    var body: some View {
        List {
            Section {
                ToolModelBindingPicker(library: library, binding: library.state.toolBindings.vision, requireVision: true) { binding in
                    do { try library.setVisionBinding(binding) } catch { errorMessage = error.localizedDescription }
                }
                status
            } footer: {
                Text(PalmiL10n.tr("ml.vision.footer"))
            }
            Section {
                Label(PalmiL10n.tr("ml.vision.native"), systemImage: "photo.on.rectangle")
                Label(PalmiL10n.tr("ml.vision.tool"), systemImage: "text.viewfinder")
            } header: {
                Text(PalmiL10n.tr("ml.vision.paths"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("ml.tool.vision"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private var status: some View {
        let targetID: UUID? = library.state.toolBindings.vision.modelID ?? library.state.defaultMainModel.modelID
        if let targetID, case .success(let resolved) = library.resolveModel(targetID, asMainModel: false) {
            switch resolved.snapshot.supports(.visionInput) {
            case .supported: ModelLibraryStatusLine(text: PalmiL10n.tr("ml.vision.ready", resolved.snapshot.modelTitle), isProblem: false)
            case .unsupported: ModelLibraryStatusLine(text: PalmiL10n.tr("ml.vision.unsupported", resolved.snapshot.modelTitle), isProblem: true)
            case .unknown: ModelLibraryStatusLine(text: PalmiL10n.tr("ml.vision.unknown", resolved.snapshot.modelTitle), isProblem: true)
            }
        } else {
            ModelLibraryStatusLine(text: PalmiL10n.tr("ml.vision.noModel"), isProblem: true)
        }
    }
}

/// 权限模式与自动审核：审核是独立请求，使用独立指令与证据；跟随主模型只是选择用哪个模型。
struct PermissionReviewSettingsScreen: View {
    @Bindable var store: ManualLabStore
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }
    private var authorization: ToolAuthorizationStore { store.toolAuthorizationStore }

    var body: some View {
        List {
            Section {
                Picker(PalmiL10n.tr("tool.authorization.title"), selection: Binding(
                    get: { authorization.mode },
                    set: { authorization.setMode($0) }
                )) {
                    ForEach(ToolAuthorizationMode.userSelectableCases) { Text($0.localizedTitle).tag($0) }
                }
                .pickerStyle(.menu)
            }

            Section {
                ToolModelBindingPicker(library: library, binding: library.state.toolBindings.permissionReview, requireVision: false) { binding in
                    do { try library.setPermissionReviewBinding(binding) } catch { errorMessage = error.localizedDescription }
                }
                let target = library.state.toolBindings.permissionReview.modelID ?? library.state.defaultMainModel.modelID
                if let target, case .failure(let issue) = library.resolveModel(target, asMainModel: false) {
                    ModelLibraryStatusLine(text: issue.localizedDescription, isProblem: true)
                } else if target == nil {
                    ModelLibraryStatusLine(text: PalmiL10n.tr("ml.review.noModel"), isProblem: true)
                }
            } header: {
                Text(PalmiL10n.tr("ml.tool.review"))
            } footer: {
                Text(PalmiL10n.tr("ml.review.footer"))
            }

            Section {
                ZStack(alignment: .topLeading) {
                    if authorization.customAutoReviewPolicy.isEmpty {
                        Text(PalmiL10n.tr("tool.authorization.autoReviewPolicy.placeholder"))
                            .foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(
                        get: { authorization.customAutoReviewPolicy },
                        set: { authorization.setCustomAutoReviewPolicy($0) }
                    ))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                }
            } header: {
                Text(PalmiL10n.tr("tool.authorization.autoReviewPolicy.title"))
            } footer: {
                Text(PalmiL10n.tr("tool.authorization.autoReviewPolicy.note"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("tool.authorization.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}

/// 网页搜索或网页抓取：本机与云端可以并存，搜索与抓取分别选择。
struct WebCapabilitySettingsScreen: View {
    @Bindable var store: ManualLabStore
    let operation: WebOperation
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }
    private var bindings: [WebCapabilityBinding] { library.state.web.bindings.filter { $0.operation == operation } }
    private var defaultID: UUID? { operation == .search ? library.state.web.defaultSearchBindingID : library.state.web.defaultFetchBindingID }

    var body: some View {
        List {
            Section {
                Picker(PalmiL10n.tr("ml.web.current"), selection: Binding<UUID?>(
                    get: { defaultID },
                    set: { id in
                        do { try library.setDefaultWebBinding(id, for: operation) } catch { errorMessage = error.localizedDescription }
                    }
                )) {
                    Text(PalmiL10n.tr("ml.web.local")).tag(Optional<UUID>.none)
                    ForEach(bindings) { binding in Text(title(binding)).tag(Optional(binding.id)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text(destinationText).font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text(PalmiL10n.tr("ml.web.current"))
            }

            if operation == .search {
                Section {
                    NavigationLink { WebSearchProviderSettingsScreen() } label: {
                        Label(PalmiL10n.tr("searchConfiguration.local.title"), systemImage: "magnifyingglass.circle")
                    }
                }
            }

            Section {
                ForEach(bindings) { binding in
                    NavigationLink { WebBindingDetailScreen(store: store, bindingID: binding.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title(binding))
                            Text(verificationText(binding)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button { isAdding = true } label: { Label(PalmiL10n.tr("ml.web.add"), systemImage: "plus.circle") }
            } header: {
                Text(PalmiL10n.tr("ml.web.cloud"))
            } footer: {
                Text(PalmiL10n.tr("ml.web.cloudFooter"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr(operation == .search ? "ml.web.search" : "ml.web.fetch"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAdding) {
            NavigationStack { WebBindingEditorScreen(store: store, operation: operation, bindingID: nil) }
        }
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func title(_ binding: WebCapabilityBinding) -> String {
        let adapter = WebAdapterCatalog.descriptor(binding.adapterID)?.title ?? binding.adapterID
        return binding.userLabel.map { "\($0) · \(adapter)" } ?? adapter
    }

    private var destinationText: String {
        guard let id = defaultID, let binding = library.state.web.binding(id) else {
            return PalmiL10n.tr(operation == .search ? "ml.web.localSearchDetail" : "ml.web.localFetchDetail")
        }
        let host = (try? binding.endpoint.resolvedURL())?.host ?? "?"
        return PalmiL10n.tr(operation == .search ? "ml.web.cloudSearchDetail" : "ml.web.cloudFetchDetail", host)
    }

    private func verificationText(_ binding: WebCapabilityBinding) -> String {
        let last = library.state.web.lastRunEvidence[binding.id]
        let success = library.state.web.lastSuccessfulEvidence[binding.id]
        switch last?.verification {
        case .verified?: return PalmiL10n.tr("ml.web.state.verified")
        case .verifiedEmpty?: return PalmiL10n.tr("ml.web.state.verifiedEmpty")
        case .notInvoked?: return PalmiL10n.tr("ml.web.state.notInvoked")
        case .unsupported?: return PalmiL10n.tr("ml.web.state.unsupported")
        case .failed?: return success == nil ? PalmiL10n.tr("ml.web.state.failed") : PalmiL10n.tr("ml.web.state.failedButVerified")
        case .unverified?: return PalmiL10n.tr("ml.web.state.unverified")
        case nil: return PalmiL10n.tr("ml.web.state.untested")
        }
    }
}

struct WebBindingDetailScreen: View {
    @Bindable var store: ManualLabStore
    let bindingID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var isVerifying = false
    @State private var result: WebOperationResult?
    @State private var isEditing = false
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }

    var body: some View {
        Group {
            if let binding = library.state.web.binding(bindingID) {
                List {
                    Section {
                        LabeledContent(PalmiL10n.tr("ml.web.adapter"), value: WebAdapterCatalog.descriptor(binding.adapterID)?.title ?? binding.adapterID)
                        LabeledContent(PalmiL10n.tr("ml.web.connection"), value: library.state.connection(binding.connectionID)?.displayName ?? PalmiL10n.tr("ml.binding.invalid"))
                        LabeledContent(PalmiL10n.tr("ml.web.endpoint"), value: binding.endpoint.displayValue)
                        if let modelID = binding.modelRecordID {
                            LabeledContent(PalmiL10n.tr("ml.tool.model"), value: library.state.model(modelID)?.title ?? PalmiL10n.tr("ml.binding.invalid"))
                        } else {
                            LabeledContent(PalmiL10n.tr("ml.tool.model"), value: PalmiL10n.tr("ml.web.noModelNeeded"))
                        }
                        if let note = WebAdapterCatalog.descriptor(binding.adapterID)?.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                        Button(PalmiL10n.tr("ml.web.edit")) { isEditing = true }
                    }
                    Section {
                        Button {
                            Task {
                                isVerifying = true
                                result = await store.webCapabilityService.verify(bindingID: bindingID)
                                isVerifying = false
                            }
                        } label: {
                            HStack {
                                Label(PalmiL10n.tr("ml.web.verify"), systemImage: "checkmark.seal")
                                if isVerifying { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(isVerifying)
                        if let result {
                            Text(PalmiL10n.tr("ml.web.verifyResult", result.status.rawValue, result.executionEvidence.rawValue, result.hits.count + result.pages.count))
                                .font(.footnote)
                            ForEach(Array(result.errors.enumerated()), id: \.offset) { _, error in
                                ModelLibraryStatusLine(text: error.localizedDescription, isProblem: true)
                            }
                        }
                        if let evidence = library.state.web.lastSuccessfulEvidence[bindingID] {
                            Text(PalmiL10n.tr("ml.web.lastSuccess", evidence.observedAt.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text(PalmiL10n.tr("ml.web.verifyFooter"))
                    }
                    Section {
                        Button(PalmiL10n.tr("ml.web.delete"), role: .destructive) {
                            do { try library.deleteWebBinding(bindingID); dismiss() } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(binding.userLabel ?? WebAdapterCatalog.descriptor(binding.adapterID)?.title ?? "")
                .sheet(isPresented: $isEditing) {
                    NavigationStack { WebBindingEditorScreen(store: store, operation: binding.operation, bindingID: bindingID) }
                }
            } else {
                ContentUnavailableView(PalmiL10n.tr("ml.binding.invalid"), systemImage: "network.slash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }
}

/// 添加或编辑云端网页服务：复用模型库连接（及其凭据），独立工具不需要模型。
struct WebBindingEditorScreen: View {
    @Bindable var store: ManualLabStore
    let operation: WebOperation
    let bindingID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var connectionID: UUID?
    @State private var adapterID = ""
    @State private var endpointText = ""
    @State private var modelID: UUID?
    @State private var label = ""
    @State private var loaded = false
    @State private var errorMessage: String?

    private var library: ModelLibraryStore { store.modelLibrary }
    private var descriptor: WebAdapterDescriptor? { WebAdapterCatalog.descriptor(adapterID) }

    var body: some View {
        Form {
            Section {
                Picker(PalmiL10n.tr("ml.web.connection"), selection: $connectionID) {
                    Text(PalmiL10n.tr("common.notSelected")).tag(Optional<UUID>.none)
                    ForEach(library.state.connections.filter { $0.chatGPTAccount == nil }) { Text($0.displayName).tag(Optional($0.id)) }
                }
                Picker(PalmiL10n.tr("ml.web.adapter"), selection: $adapterID) {
                    Text(PalmiL10n.tr("common.notSelected")).tag("")
                    ForEach(WebAdapterCatalog.adapters(for: operation)) { Text($0.title).tag($0.id) }
                }
                if let descriptor { Text(descriptor.note).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text(PalmiL10n.tr("ml.web.editorFooter"))
            }
            .onChange(of: adapterID) { _, _ in suggest() }
            .onChange(of: connectionID) { _, _ in suggest() }

            Section {
                TextField("https://", text: $endpointText)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text(PalmiL10n.tr("ml.web.endpoint"))
            } footer: {
                Text(PalmiL10n.tr("ml.web.endpointFooter"))
            }

            if descriptor?.requiresModel == true {
                Section {
                    Picker(PalmiL10n.tr("ml.tool.model"), selection: $modelID) {
                        Text(PalmiL10n.tr("common.notSelected")).tag(Optional<UUID>.none)
                        ForEach(library.state.models.filter { $0.connectionID == connectionID }) { Text($0.title).tag(Optional($0.id)) }
                    }
                } footer: {
                    Text(PalmiL10n.tr("ml.web.modelFooter"))
                }
            }

            Section(PalmiL10n.tr("ml.connection.label")) {
                TextField(PalmiL10n.tr("ml.connection.labelPlaceholder"), text: $label)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(PalmiL10n.tr(bindingID == nil ? "ml.web.add" : "ml.web.edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("common.cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(PalmiL10n.tr("common.save")) { save() }
                    .disabled(connectionID == nil || adapterID.isEmpty || endpointText.isEmpty || (descriptor?.requiresModel == true && modelID == nil))
            }
        }
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let bindingID, let binding = library.state.web.binding(bindingID) else { return }
        connectionID = binding.connectionID
        adapterID = binding.adapterID
        modelID = binding.modelRecordID
        label = binding.userLabel ?? ""
        endpointText = (try? binding.endpoint.resolvedURL().absoluteString) ?? ""
    }

    private func suggest() {
        guard bindingID == nil, let descriptor, let connectionID, let connection = library.state.connection(connectionID),
              let suggestion = WebAdapterCatalog.suggestedEndpoint(for: descriptor, connection: connection),
              let url = try? suggestion.resolvedURL() else { return }
        endpointText = url.absoluteString
        if descriptor.requiresModel, modelID == nil {
            modelID = library.state.models.first { $0.connectionID == connectionID && !$0.imageGenerationOnly }?.id
        }
    }

    private func save() {
        guard let connectionID, let descriptor else { return }
        let existing = bindingID.flatMap { library.state.web.binding($0) }
        let binding = WebCapabilityBinding(
            id: bindingID ?? UUID(),
            operation: operation,
            adapterID: descriptor.id,
            executionKind: descriptor.executionKind,
            connectionID: connectionID,
            modelRecordID: descriptor.requiresModel ? modelID : nil,
            endpoint: .explicitURL(endpointText.trimmingCharacters(in: .whitespacesAndNewlines)),
            options: existing?.options ?? [:],
            revision: existing?.revision ?? 1,
            userLabel: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label,
            createdAt: existing?.createdAt ?? .now,
            updatedAt: .now
        )
        do {
            try library.upsertWebBinding(binding)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
