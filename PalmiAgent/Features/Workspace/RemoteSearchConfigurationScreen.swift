import SwiftUI

private enum RemoteSearchConfigurationRoute: Hashable, Identifiable {
    case create
    case edit(UUID)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let id): "edit.\(id.uuidString)"
        }
    }
}

struct RemoteSearchConfigurationScreen: View {
    @Bindable var store: RemoteSearchConfigurationStore
    @Bindable var permissionStore: ToolPermissionStore
    let remoteWebSearchService: RemoteWebSearchService
    @State private var route: RemoteSearchConfigurationRoute?
    @State private var pendingDeletionID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section(PalmiL10n.tr("remoteSearch.currentConfiguration")) {
                if store.configurations.isEmpty {
                    Text(PalmiL10n.tr("remoteSearch.noConfigurations"))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(
                        PalmiL10n.tr("remoteSearch.currentConfiguration"),
                        selection: Binding<UUID?>(
                            get: {
                                store.activeConfigurationID()
                                    ?? store.preferredRemoteConfigurationSnapshot()?.id
                            },
                            set: { id in
                                if let id { activate(id) }
                            }
                        )
                    ) {
                        ForEach(store.configurations) { configuration in
                            Text(configuration.displayName)
                                .tag(Optional(configuration.id))
                        }
                    }
                }
            }

            Section(PalmiL10n.tr("remoteSearch.configurations")) {
                ForEach(store.configurations) { configuration in
                    Button {
                        route = .edit(configuration.id)
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(configuration.displayName)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("\(configuration.apiProtocol.localizedTitle) · \(configuration.modelName)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(configuration.baseURLString)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 12)
                            if store.activeConfigurationID() == configuration.id {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel(PalmiL10n.tr("remoteSearch.active"))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDeletionID = configuration.id
                        } label: {
                            Label(
                                PalmiL10n.tr("remoteSearch.delete"),
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("remoteSearch.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    route = .create
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(PalmiL10n.tr("remoteSearch.add"))
            }
        }
        .navigationDestination(item: $route) { route in
            switch route {
            case .create:
                RemoteSearchConfigurationEditorScreen(
                    store: store,
                    permissionStore: permissionStore,
                    remoteWebSearchService: remoteWebSearchService,
                    configurationID: nil
                )
            case .edit(let id):
                RemoteSearchConfigurationEditorScreen(
                    store: store,
                    permissionStore: permissionStore,
                    remoteWebSearchService: remoteWebSearchService,
                    configurationID: id
                )
            }
        }
        .confirmationDialog(
            deletionConfirmationTitle,
            isPresented: Binding(
                get: { pendingDeletionID != nil },
                set: { isPresented in
                    if !isPresented { pendingDeletionID = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(PalmiL10n.tr("remoteSearch.delete"), role: .destructive) {
                deletePendingConfiguration()
            }
            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {
                pendingDeletionID = nil
            }
        } message: {
            Text(PalmiL10n.tr("remoteSearch.delete.confirmMessage"))
        }
        .alert(
            PalmiL10n.tr("remoteSearch.error.title"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented { errorMessage = nil }
                }
            )
        ) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { store.refresh() }
    }

    private var deletionConfirmationTitle: String {
        guard let id = pendingDeletionID,
              let configuration = store.configuration(id: id) else {
            return PalmiL10n.tr("remoteSearch.delete")
        }
        return PalmiL10n.tr(
            "remoteSearch.delete.confirmTitle",
            configuration.displayName
        )
    }

    private func activate(_ id: UUID) {
        do {
            try store.activateConfiguration(id)
            permissionStore.setEnabled(true, for: .searchWeb)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePendingConfiguration() {
        guard let id = pendingDeletionID else { return }
        pendingDeletionID = nil
        do {
            try store.deleteConfiguration(id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct RemoteSearchConfigurationEditorScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: RemoteSearchConfigurationStore
    @Bindable var permissionStore: ToolPermissionStore
    let remoteWebSearchService: RemoteWebSearchService
    let configurationID: UUID?
    let maskedAPIKey: String?

    @State private var displayName: String
    @State private var baseURLString: String
    @State private var modelName: String
    @State private var apiProtocol: RemoteSearchAPIProtocol
    @State private var apiKeyDraft: String
    @State private var isValidating = false
    @State private var notice: RemoteSearchEditorNotice?

    init(
        store: RemoteSearchConfigurationStore,
        permissionStore: ToolPermissionStore,
        remoteWebSearchService: RemoteWebSearchService,
        configurationID: UUID?
    ) {
        self.store = store
        self.permissionStore = permissionStore
        self.remoteWebSearchService = remoteWebSearchService
        self.configurationID = configurationID
        let configuration = configurationID.flatMap(store.configuration(id:))
        maskedAPIKey = configuration?.maskedAPIKey
        _displayName = State(initialValue: configuration?.displayName ?? "")
        _baseURLString = State(initialValue: configuration?.baseURLString ?? "")
        _modelName = State(initialValue: configuration?.modelName ?? "")
        _apiProtocol = State(initialValue: configuration?.apiProtocol ?? .responses)
        _apiKeyDraft = State(initialValue: "")
    }

    var body: some View {
        Form {
            Section {
                TextField(
                    PalmiL10n.tr("remoteSearch.field.displayName"),
                    text: $displayName
                )

                Picker(
                    PalmiL10n.tr("remoteSearch.field.protocol"),
                    selection: $apiProtocol
                ) {
                    ForEach(RemoteSearchAPIProtocol.allCases) { apiProtocol in
                        Text(apiProtocol.localizedTitle).tag(apiProtocol)
                    }
                }

                TextField(
                    PalmiL10n.tr("remoteSearch.field.baseURL"),
                    text: $baseURLString
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                TextField(
                    PalmiL10n.tr("remoteSearch.field.modelName"),
                    text: $modelName
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            Section {
                SecureField(
                    PalmiL10n.tr("remoteSearch.field.apiKey"),
                    text: $apiKeyDraft
                )
            } footer: {
                if let maskedAPIKey {
                    Text(
                        PalmiL10n.tr(
                            "remoteSearch.apiKey.keepExisting",
                            maskedAPIKey
                        )
                    )
                }
            }

            Section {
                Button {
                    validateConnectivity()
                } label: {
                    if isValidating {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(PalmiL10n.tr("remoteSearch.validating"))
                        }
                    } else {
                        Text(PalmiL10n.tr("remoteSearch.validate"))
                    }
                }
                .disabled(isValidationDisabled || isValidating)

                Button(PalmiL10n.tr("remoteSearch.saveAndEnable")) {
                    saveAndEnable()
                }
                .disabled(isSaveDisabled)
            }
        }
        .navigationTitle(
            PalmiL10n.tr(
                configurationID == nil ? "remoteSearch.new" : "remoteSearch.edit"
            )
        )
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(PalmiL10n.tr("common.ok")))
            )
        }
    }

    private var isSaveDisabled: Bool {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        (configurationID == nil && apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var isValidationDisabled: Bool {
        isSaveDisabled
    }

    private func validateConnectivity() {
        isValidating = true
        Task {
            defer { isValidating = false }
            do {
                let configuration = transientConfigurationSnapshot()
                let apiKey = try validationAPIKey()
                try await remoteWebSearchService.validateConnectivity(
                    configuration: configuration,
                    apiKey: apiKey
                )
                notice = .success
            } catch {
                notice = .failure(error.localizedDescription)
            }
        }
    }

    private func transientConfigurationSnapshot() -> RemoteSearchConfigurationSnapshot {
        let now = Date.now
        return RemoteSearchConfigurationSnapshot(
            record: RemoteSearchConfigurationRecord(
                id: configurationID ?? UUID(),
                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURLString: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines),
                modelName: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
                apiProtocol: apiProtocol,
                createdAt: now,
                updatedAt: now
            ),
            hasAPIKey: true,
            maskedAPIKey: nil
        )
    }

    private func validationAPIKey() throws -> String {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let configurationID else {
            throw AppError.invalidState("API Key 不能为空。")
        }
        return try store.apiKey(for: configurationID)
    }

    private func saveAndEnable() {
        do {
            let id = try store.saveConfiguration(
                id: configurationID,
                displayName: displayName,
                baseURLString: baseURLString,
                modelName: modelName,
                apiProtocol: apiProtocol,
                apiKey: apiKeyDraft
            )
            try store.activateConfiguration(id)
            permissionStore.setEnabled(true, for: .searchWeb)
            dismiss()
        } catch {
            notice = .failure(error.localizedDescription)
        }
    }
}

private enum RemoteSearchEditorNotice: Identifiable {
    case success
    case failure(String)

    var id: String {
        switch self {
        case .success: "success"
        case .failure(let message): "failure.\(message)"
        }
    }

    var title: String {
        switch self {
        case .success:
            PalmiL10n.tr("remoteSearch.validation.success.title")
        case .failure:
            PalmiL10n.tr("remoteSearch.error.title")
        }
    }

    var message: String {
        switch self {
        case .success:
            PalmiL10n.tr("remoteSearch.validation.success.message")
        case .failure(let message):
            message
        }
    }
}
