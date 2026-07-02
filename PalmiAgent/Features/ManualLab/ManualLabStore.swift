import Observation
import UIKit

struct SharePayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct APIConfigurationFeedback {
    let message: String
    let isError: Bool

    static func success(_ message: String) -> APIConfigurationFeedback {
        APIConfigurationFeedback(message: message, isError: false)
    }

    static func failure(_ message: String) -> APIConfigurationFeedback {
        APIConfigurationFeedback(message: message, isError: true)
    }
}

enum APIConnectionValidationState: Equatable {
    case idle
    case validating
    case success
    case failure(String)
}

struct APIProfileDraftState {
    let providerID: APIProviderID
    let profileID: UUID
    var profileName: String
    var selectedAccessModeID: APIAccessModeID
    var defaultModelID: String
    var reasoningModelID: String
    var multimodalModelID: String
    var lightweightModelID: String
    var apiKeyDraft: String
    var customBaseURLDraft: String
    var selectedLMStudioServer: LMStudioDiscoveredServer?
}

@MainActor
@Observable
final class ManualLabStore {
    let actions: [ToolAction]
    let executor: ActionExecutor
    let apiConfigurationStore: APIConfigurationStore
    let modelPlanStore: ModelPlanStore
    let llmToolCallingService: LLMToolCallingService
    let apiConnectionValidationService: APIConnectionValidationService
    let modelCandidateValidationService: ModelCandidateValidationService
    let lmStudioDiscoveryService: LMStudioDiscoveryService
    let workspaceStore: WorkspaceStore
    let toolPermissionStore: ToolPermissionStore
    let toolAuthorizationStore: ToolAuthorizationStore

    var lastResult: ToolResult?
    var executionLog: [ToolExecutionRecord] = []
    var runningActionID: ToolActionID?
    var presentation: MediaPresentation?
    var sharePayload: SharePayload?
    var naturalLanguagePrompt = ""
    var isRunningNaturalLanguageCall = false
    var llmSessions: [LLMToolSession] = []
    var llmStatusMessage: String?
    var llmStreamingPreview: String?
    private var apiSnapshots: [APIProviderID: APIProviderConfigurationSnapshot] = [:]
    private var apiProfiles: [APIProviderID: [APIConfigurationProfileSnapshot]] = [:]
    private var apiDrafts: [UUID: APIProfileDraftState] = [:]
    private var apiFeedbacks: [UUID: APIConfigurationFeedback] = [:]
    private var apiConnectionFeedbacks: [UUID: APIConfigurationFeedback] = [:]
    private var apiConnectionStates: [UUID: [APIModelRole: APIConnectionValidationState]] = [:]
    private var validatingProfileIDs: Set<UUID> = []
    private var fetchingRemoteModelProfileIDs: Set<UUID> = []
    private var lmStudioDiscoveredServers: [UUID: [LMStudioDiscoveredServer]] = [:]
    private var discoveringLMStudioProfileIDs: Set<UUID> = []

    init(
        actions: [ToolAction],
        executor: ActionExecutor,
        apiConfigurationStore: APIConfigurationStore,
        modelPlanStore: ModelPlanStore,
        llmToolCallingService: LLMToolCallingService,
        apiConnectionValidationService: APIConnectionValidationService,
        modelCandidateValidationService: ModelCandidateValidationService,
        lmStudioDiscoveryService: LMStudioDiscoveryService,
        workspaceStore: WorkspaceStore,
        toolPermissionStore: ToolPermissionStore,
        toolAuthorizationStore: ToolAuthorizationStore
    ) {
        self.actions = actions
        self.executor = executor
        self.apiConfigurationStore = apiConfigurationStore
        self.modelPlanStore = modelPlanStore
        self.llmToolCallingService = llmToolCallingService
        self.apiConnectionValidationService = apiConnectionValidationService
        self.modelCandidateValidationService = modelCandidateValidationService
        self.lmStudioDiscoveryService = lmStudioDiscoveryService
        self.workspaceStore = workspaceStore
        self.toolPermissionStore = toolPermissionStore
        self.toolAuthorizationStore = toolAuthorizationStore
        refreshAPIConfiguration()
    }

    var groupedActions: [(category: ToolCategory, actions: [ToolAction])] {
        ActionCatalog.grouped()
    }

    var liveCount: Int {
        actions.filter { $0.availability == .live }.count
    }

    var partialCount: Int {
        actions.filter { $0.availability == .partial }.count
    }

    var deferredCount: Int {
        actions.filter { $0.availability == .deferred }.count
    }

    var configuredProviderCount: Int {
        apiSnapshots.values.filter(\.isConfigured).count
    }

    var totalProviderCount: Int {
        APIProviderID.allCases.count
    }

    var exposedToolCount: Int {
        toolPermissionStore.enabledActionCount(in: actions)
    }

    var enabledActions: [ToolAction] {
        toolPermissionStore.enabledActions(from: actions)
    }

    var activeProviderID: APIProviderID {
        apiConfigurationStore.activeProviderID()
    }

    var activeLLMSnapshot: APIProviderConfigurationSnapshot {
        snapshot(for: activeProviderID)
    }

    var canSubmitNaturalLanguagePrompt: Bool {
        activeLLMSnapshot.isConfigured &&
        !naturalLanguagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isRunningNaturalLanguageCall
    }

    func run(_ action: ToolAction) {
        runningActionID = action.id
        Task {
            let outcome = await executor.execute(action, arguments: .empty)
            self.runningActionID = nil
            self.applyExecutionOutcome(outcome, for: action)
        }
    }

    func handleImageResult(_ image: UIImage?) {
        guard let presentation else { return }
        let details: String
        let status: ToolResult.Status
        if let image {
            details = PalmiL10n.tr("manualLab.callback.imageReceived", Int(image.size.width), Int(image.size.height))
            status = .success
        } else {
            details = PalmiL10n.tr("manualLab.callback.imageCancelled")
            status = .warning
        }
        appendCallbackResult(for: presentation.actionID, summary: PalmiL10n.tr("manualLab.callback.mediaCompleted"), details: details, status: status)
        self.presentation = nil
    }

    func handleDocumentScan(_ pageCount: Int?) {
        guard let presentation else { return }
        let details = pageCount.map { PalmiL10n.tr("manualLab.callback.documentScanned", $0) } ?? PalmiL10n.tr("manualLab.callback.scanCancelled")
        appendCallbackResult(for: presentation.actionID, summary: PalmiL10n.tr("manualLab.callback.documentCompleted"), details: details, status: pageCount == nil ? .warning : .success)
        self.presentation = nil
    }

    func handleTextScan(_ text: String?) {
        guard let presentation else { return }
        let details = text.map { PalmiL10n.tr("manualLab.callback.textRecognized", $0) } ?? PalmiL10n.tr("manualLab.callback.textScanEmpty")
        appendCallbackResult(for: presentation.actionID, summary: PalmiL10n.tr("manualLab.callback.liveTextReturned"), details: details, status: text == nil ? .warning : .success)
        self.presentation = nil
    }

    func dismissPresentation() {
        presentation = nil
    }

    func runNaturalLanguageToolCall() {
        let trimmedPrompt = naturalLanguagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            llmStatusMessage = PalmiL10n.tr("manualLab.llm.enterPrompt")
            return
        }

        isRunningNaturalLanguageCall = true
        llmStatusMessage = nil
        llmStreamingPreview = nil

        Task {
            do {
                let session = try await llmToolCallingService.runSession(
                    prompt: trimmedPrompt,
                    providerID: activeProviderID,
                    actions: enabledActions,
                    onEvent: { event in
                        switch event {
                        case .planningReceived(_, let tokens):
                            self.llmStatusMessage = PalmiL10n.tr("manualLab.llm.planningCompleted", tokens)
                        case .toolStarted:
                            self.llmStreamingPreview = nil
                            self.llmStatusMessage = PalmiL10n.tr("manualLab.llm.toolRunning")
                        case .toolFinished:
                            self.llmStatusMessage = PalmiL10n.tr("manualLab.llm.toolFinished")
                        case .streamingDelta(let text):
                            self.llmStreamingPreview = (self.llmStreamingPreview ?? "") + text
                        case .tokenUpdate(let tokens):
                            self.llmStatusMessage = PalmiL10n.tr("manualLab.llm.summarizing", tokens)
                        case .finalReplyReceived(_, let tokens):
                            self.llmStatusMessage = PalmiL10n.tr("manualLab.llm.modelCompleted", tokens)
                        }
                    }
                ) { action, arguments in
                    let outcome = await self.executor.execute(action, arguments: arguments)
                    self.applyExecutionOutcome(outcome, for: action)
                    return outcome
                }

                self.llmSessions.insert(session, at: 0)
                self.naturalLanguagePrompt = ""
                self.llmStreamingPreview = nil
            } catch {
                self.llmStatusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.llmStreamingPreview = nil
            }

            self.isRunningNaturalLanguageCall = false
        }
    }

    func usePromptExample(_ prompt: String) {
        naturalLanguagePrompt = prompt
        llmStatusMessage = nil
        llmStreamingPreview = nil
    }

    func setActiveProviderID(_ providerID: APIProviderID) {
        apiConfigurationStore.setActiveProviderID(providerID)
        refreshAPIConfiguration()
    }

    func snapshot(for providerID: APIProviderID) -> APIProviderConfigurationSnapshot {
        if let snapshot = apiSnapshots[providerID] {
            return snapshot
        }
        let snapshot = apiConfigurationStore.snapshot(for: providerID)
        apiSnapshots[providerID] = snapshot
        return snapshot
    }

    func profiles(for providerID: APIProviderID) -> [APIConfigurationProfileSnapshot] {
        if let profiles = apiProfiles[providerID] {
            return profiles
        }
        let profiles = apiConfigurationStore.profiles(for: providerID)
        apiProfiles[providerID] = profiles
        return profiles
    }

    func editableModelRoles(for providerID: APIProviderID) -> [APIModelRole] {
        snapshot(for: providerID).provider.editableModelRoles
    }

    func supportsManualModelSelection(for providerID: APIProviderID) -> Bool {
        snapshot(for: providerID).provider.supportsManualModelSelection
    }

    func supportsServerDiscovery(for providerID: APIProviderID) -> Bool {
        snapshot(for: providerID).provider.supportsServerDiscovery
    }

    func supportsRemoteModelDiscovery(for providerID: APIProviderID) -> Bool {
        snapshot(for: providerID).provider.supportsRemoteModelDiscovery
    }

    func createProfile(for providerID: APIProviderID) -> UUID {
        let profileID = apiConfigurationStore.createProfile(for: providerID)
        refreshAPIConfiguration(for: providerID)
        _ = draftState(for: providerID, profileID: profileID)
        return profileID
    }

    func activateProfile(_ profileID: UUID, for providerID: APIProviderID) {
        apiConfigurationStore.activateProfile(profileID, for: providerID)
        refreshAPIConfiguration(for: providerID)
    }

    func canDeleteProfile(_ profileID: UUID, for providerID: APIProviderID) -> Bool {
        profiles(for: providerID).contains { profile in
            profile.id == profileID &&
            (
                profile.isConfigured ||
                profile.hasAPIKey ||
                !profile.customBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                profile.selectedServer != nil
            )
        }
    }

    func deleteProfile(_ profileID: UUID, for providerID: APIProviderID) throws {
        try apiConfigurationStore.deleteProfile(profileID, for: providerID)
        apiDrafts.removeValue(forKey: profileID)
        apiFeedbacks.removeValue(forKey: profileID)
        apiConnectionFeedbacks.removeValue(forKey: profileID)
        apiConnectionStates.removeValue(forKey: profileID)
        lmStudioDiscoveredServers.removeValue(forKey: profileID)
        discoveringLMStudioProfileIDs.remove(profileID)
        validatingProfileIDs.remove(profileID)
        refreshAPIConfiguration(for: providerID)
    }

    func profileName(for providerID: APIProviderID, profileID: UUID? = nil) -> String {
        draftState(for: providerID, profileID: profileID).profileName
    }

    func setProfileName(_ name: String, for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        var draft = draftState(for: providerID, profileID: resolvedProfileID)
        draft.profileName = name
        apiDrafts[resolvedProfileID] = draft
        apiFeedbacks[resolvedProfileID] = nil
    }

    func availableModels(for providerID: APIProviderID, profileID: UUID? = nil) -> [APIModelDefinition] {
        availableModels(for: providerID, role: .defaultModel, profileID: profileID)
    }

    func availableModels(
        for providerID: APIProviderID,
        role: APIModelRole,
        profileID: UUID? = nil
    ) -> [APIModelDefinition] {
        let provider = snapshot(for: providerID).provider
        guard provider.supportsManualModelSelection else {
            return [APIModelDefinition.automatic(for: role)]
        }
        return selectedAccessMode(for: providerID, profileID: profileID).availableModels(for: role)
    }

    func catalogModels(
        for providerID: APIProviderID,
        role: APIModelRole,
        profileID: UUID? = nil
    ) -> [APIModelDefinition] {
        let provider = snapshot(for: providerID).provider
        guard provider.supportsManualModelSelection else {
            return [APIModelDefinition.automatic(for: role)]
        }
        let accessModeID = selectedAccessModeID(for: providerID, profileID: profileID)
        let baseAccessMode = provider.accessMode(withID: accessModeID) ?? provider.preferredAccessMode
        return baseAccessMode.availableModels(for: role)
    }

    func remoteModels(
        for providerID: APIProviderID,
        role: APIModelRole,
        profileID: UUID? = nil
    ) -> [APIModelDefinition] {
        let catalogIDs = Set(catalogModels(for: providerID, role: role, profileID: profileID).map(\.id))
        return availableModels(for: providerID, role: role, profileID: profileID)
            .filter { !catalogIDs.contains($0.id) }
    }

    func availableAccessModes(for providerID: APIProviderID) -> [APIAccessModeDefinition] {
        snapshot(for: providerID).provider.accessModes
    }

    func selectedAccessModeID(for providerID: APIProviderID) -> APIAccessModeID {
        selectedAccessModeID(for: providerID, profileID: nil)
    }

    func selectedAccessModeID(for providerID: APIProviderID, profileID: UUID? = nil) -> APIAccessModeID {
        draftState(for: providerID, profileID: profileID).selectedAccessModeID
    }

    func selectedAccessMode(for providerID: APIProviderID) -> APIAccessModeDefinition {
        selectedAccessMode(for: providerID, profileID: nil)
    }

    func selectedAccessMode(for providerID: APIProviderID, profileID: UUID? = nil) -> APIAccessModeDefinition {
        let activeSnapshot = snapshot(for: providerID)
        let accessModeID = selectedAccessModeID(for: providerID, profileID: profileID)
        let baseAccessMode = activeSnapshot.provider.accessMode(withID: accessModeID) ?? activeSnapshot.selectedAccessMode
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        if let profile = profiles(for: providerID).first(where: { $0.id == resolvedProfileID }) {
            return baseAccessMode.mergingRemoteModels(profile.remoteModelDefinitions)
        }
        return baseAccessMode
    }

    func selectedModelID(for providerID: APIProviderID) -> String {
        selectedModelID(for: providerID, role: .defaultModel, profileID: nil)
    }

    func selectedModelID(
        for providerID: APIProviderID,
        role: APIModelRole,
        profileID: UUID? = nil
    ) -> String {
        let draft = draftState(for: providerID, profileID: profileID)
        switch role {
        case .defaultModel:
            return draft.defaultModelID
        case .reasoningModel:
            return draft.reasoningModelID
        case .multimodalModel:
            return draft.multimodalModelID
        case .lightweightModel:
            return draft.lightweightModelID
        }
    }

    func setSelectedAccessModeID(_ accessModeID: APIAccessModeID, for providerID: APIProviderID) {
        setSelectedAccessModeID(accessModeID, for: providerID, profileID: nil)
    }

    func setSelectedAccessModeID(
        _ accessModeID: APIAccessModeID,
        for providerID: APIProviderID,
        profileID: UUID? = nil
    ) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        let activeSnapshot = snapshot(for: providerID)
        guard let accessMode = activeSnapshot.provider.accessMode(withID: accessModeID) else {
            return
        }

        var draft = draftState(for: providerID, profileID: resolvedProfileID)
        draft.selectedAccessModeID = accessModeID
        draft.defaultModelID = validModelID(
            currentModelID: draft.defaultModelID,
            for: activeSnapshot.provider,
            for: accessMode,
            role: .defaultModel
        )
        draft.reasoningModelID = validModelID(
            currentModelID: draft.reasoningModelID,
            for: activeSnapshot.provider,
            for: accessMode,
            role: .reasoningModel
        )
        draft.multimodalModelID = validModelID(
            currentModelID: draft.multimodalModelID,
            for: activeSnapshot.provider,
            for: accessMode,
            role: .multimodalModel
        )
        draft.lightweightModelID = validModelID(
            currentModelID: draft.lightweightModelID,
            for: activeSnapshot.provider,
            for: accessMode,
            role: .lightweightModel
        )
        apiDrafts[resolvedProfileID] = draft
        apiFeedbacks[resolvedProfileID] = nil
        resetConnectionValidation(for: resolvedProfileID)
    }

    func setSelectedModelID(_ modelID: String, for providerID: APIProviderID) {
        setSelectedModelID(modelID, role: .defaultModel, for: providerID, profileID: nil)
    }

    func setSelectedModelID(
        _ modelID: String,
        role: APIModelRole,
        for providerID: APIProviderID,
        profileID: UUID? = nil
    ) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        var draft = draftState(for: providerID, profileID: resolvedProfileID)
        switch role {
        case .defaultModel:
            draft.defaultModelID = modelID
        case .reasoningModel:
            draft.reasoningModelID = modelID
        case .multimodalModel:
            draft.multimodalModelID = modelID
        case .lightweightModel:
            draft.lightweightModelID = modelID
        }
        apiDrafts[resolvedProfileID] = draft
        apiFeedbacks[resolvedProfileID] = nil
        resetConnectionValidation(for: resolvedProfileID)
    }

    func selectedModel(for providerID: APIProviderID) -> APIModelDefinition {
        selectedModel(for: providerID, role: .defaultModel, profileID: nil)
    }

    func selectedModel(
        for providerID: APIProviderID,
        role: APIModelRole,
        profileID: UUID? = nil
    ) -> APIModelDefinition {
        let provider = snapshot(for: providerID).provider
        let draft = draftState(for: providerID, profileID: profileID)
        if !provider.supportsManualModelSelection, let selectedServer = draft.selectedLMStudioServer {
            if role == .multimodalModel {
                return selectedServer.configuredVisionModelDefinition ?? .noMultimodal
            }
            return selectedServer.configuredModelDefinition ?? selectedAccessMode(for: providerID, profileID: profileID).defaultModel
        }

        let accessMode = selectedAccessMode(for: providerID, profileID: profileID)
        let resolvedDefaultModel = resolveSelectedModel(
            selectedModelID(for: providerID, role: .defaultModel, profileID: profileID),
            role: .defaultModel,
            provider: provider,
            accessMode: accessMode,
            defaultModel: accessMode.defaultModel
        )
        return resolveSelectedModel(
            selectedModelID(for: providerID, role: role, profileID: profileID),
            role: role,
            provider: provider,
            accessMode: accessMode,
            defaultModel: resolvedDefaultModel
        )
    }

    func apiKeyDraft(for providerID: APIProviderID) -> String {
        apiKeyDraft(for: providerID, profileID: nil)
    }

    func apiKeyDraft(for providerID: APIProviderID, profileID: UUID? = nil) -> String {
        draftState(for: providerID, profileID: profileID).apiKeyDraft
    }

    func setAPIKeyDraft(_ apiKey: String, for providerID: APIProviderID) {
        setAPIKeyDraft(apiKey, for: providerID, profileID: nil)
    }

    func setAPIKeyDraft(_ apiKey: String, for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        var draft = draftState(for: providerID, profileID: resolvedProfileID)
        draft.apiKeyDraft = apiKey
        apiDrafts[resolvedProfileID] = draft
        apiFeedbacks[resolvedProfileID] = nil
        resetConnectionValidation(for: resolvedProfileID)
    }

    func customBaseURLDraft(for providerID: APIProviderID, profileID: UUID? = nil) -> String {
        draftState(for: providerID, profileID: profileID).customBaseURLDraft
    }

    func setCustomBaseURLDraft(_ baseURL: String, for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        var draft = draftState(for: providerID, profileID: resolvedProfileID)
        draft.customBaseURLDraft = baseURL
        if !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.selectedLMStudioServer = nil
        }
        apiDrafts[resolvedProfileID] = draft
        apiFeedbacks[resolvedProfileID] = nil
        resetConnectionValidation(for: resolvedProfileID)
    }

    func selectedLMStudioServer(for providerID: APIProviderID, profileID: UUID? = nil) -> LMStudioDiscoveredServer? {
        draftState(for: providerID, profileID: profileID).selectedLMStudioServer
    }

    func discoveredLMStudioServers(for providerID: APIProviderID, profileID: UUID? = nil) -> [LMStudioDiscoveredServer] {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        return lmStudioDiscoveredServers[resolvedProfileID] ?? []
    }

    func isDiscoveringLMStudioServers(for providerID: APIProviderID, profileID: UUID? = nil) -> Bool {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        return discoveringLMStudioProfileIDs.contains(resolvedProfileID)
    }

    func autoConfigureLMStudio(for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        let candidateURLs = prioritizedLMStudioCandidateURLs(for: providerID, profileID: resolvedProfileID)
        let apiToken = nonEmpty(apiKeyDraft(for: providerID, profileID: resolvedProfileID))

        discoveringLMStudioProfileIDs.insert(resolvedProfileID)
        apiFeedbacks[resolvedProfileID] = nil
        apiConnectionFeedbacks[resolvedProfileID] = nil
        resetConnectionValidation(for: resolvedProfileID)

        Task {
            defer {
                discoveringLMStudioProfileIDs.remove(resolvedProfileID)
            }

            let discoveryResult = await resolveAutoConfiguredLMStudioSelection(
                candidateURLs: candidateURLs,
                apiToken: apiToken
            )

            lmStudioDiscoveredServers[resolvedProfileID] = discoveryResult.discoveredServers

            guard let selectedServer = discoveryResult.selectedServer else {
                if let lastError = discoveryResult.lastError {
                    apiFeedbacks[resolvedProfileID] = .failure(lastError.localizedDescription)
                } else {
                    apiFeedbacks[resolvedProfileID] = .failure(
                        PalmiL10n.tr("manualLab.lmStudio.autoDiscoveryFailed")
                    )
                }
                return
            }

            do {
                selectLMStudioServer(selectedServer, for: providerID, profileID: resolvedProfileID)
                let savedProfile = try persistDraft(for: providerID, profileID: resolvedProfileID)
                let validationPassed = await validateAutoConfiguredLMStudioConnection(
                    for: providerID,
                    profileID: resolvedProfileID
                )

                if validationPassed {
                    apiFeedbacks[resolvedProfileID] = .success(
                        PalmiL10n.tr("manualLab.lmStudio.autoConfiguredValidated", savedProfile.profileName)
                    )
                } else if selectedServer.requiresAuthentication && apiToken == nil {
                    apiFeedbacks[resolvedProfileID] = .success(
                        PalmiL10n.tr("manualLab.lmStudio.serverSavedNeedsKey", savedProfile.profileName)
                    )
                } else {
                    apiFeedbacks[resolvedProfileID] = .success(
                        PalmiL10n.tr("manualLab.lmStudio.serverSaved", savedProfile.profileName)
                    )
                }
            } catch {
                apiFeedbacks[resolvedProfileID] = .failure(error.localizedDescription)
            }
        }
    }

    func discoverLMStudioServers(for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        discoveringLMStudioProfileIDs.insert(resolvedProfileID)
        apiFeedbacks[resolvedProfileID] = nil

        Task {
            let servers = await lmStudioDiscoveryService.discoverServers()
            lmStudioDiscoveredServers[resolvedProfileID] = servers
            discoveringLMStudioProfileIDs.remove(resolvedProfileID)

            if let best = servers.first {
                selectLMStudioServer(best, for: providerID, profileID: resolvedProfileID)
                apiFeedbacks[resolvedProfileID] = .success(PalmiL10n.tr("manualLab.lmStudio.discoveredServers", servers.count))
            } else {
                apiFeedbacks[resolvedProfileID] = .failure(PalmiL10n.tr("manualLab.lmStudio.discoveryFailed"))
            }
        }
    }

    func refreshSelectedLMStudioServer(for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        guard let baseURLString = draftState(for: providerID, profileID: resolvedProfileID)
            .selectedLMStudioServer?
            .baseURLString ?? nonEmpty(customBaseURLDraft(for: providerID, profileID: resolvedProfileID)),
              let baseURL = normalizedLMStudioCandidateURL(from: baseURLString) else {
            apiFeedbacks[resolvedProfileID] = .failure(PalmiL10n.tr("manualLab.lmStudio.noRefreshableServer"))
            return
        }

        Task {
            do {
                let refreshed = try await lmStudioDiscoveryService.refreshServer(
                    baseURL: baseURL,
                    apiToken: nonEmpty(apiKeyDraft(for: providerID, profileID: resolvedProfileID))
                )
                selectLMStudioServer(refreshed, for: providerID, profileID: resolvedProfileID)
                apiFeedbacks[resolvedProfileID] = .success(PalmiL10n.tr("manualLab.lmStudio.serverRefreshed"))
            } catch {
                apiFeedbacks[resolvedProfileID] = .failure(error.localizedDescription)
            }
        }
    }

    func selectLMStudioServer(
        _ server: LMStudioDiscoveredServer,
        for providerID: APIProviderID,
        profileID: UUID? = nil
    ) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        var draft = draftState(for: providerID, profileID: resolvedProfileID)
        draft.selectedLMStudioServer = server
        draft.customBaseURLDraft = server.baseURLString
        apiDrafts[resolvedProfileID] = draft
        apiFeedbacks[resolvedProfileID] = nil
        resetConnectionValidation(for: resolvedProfileID)
    }

    func feedback(for providerID: APIProviderID) -> APIConfigurationFeedback? {
        feedback(for: providerID, profileID: nil)
    }

    func feedback(for providerID: APIProviderID, profileID: UUID? = nil) -> APIConfigurationFeedback? {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        return apiFeedbacks[resolvedProfileID]
    }

    func connectionFeedback(for providerID: APIProviderID, profileID: UUID? = nil) -> APIConfigurationFeedback? {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        return apiConnectionFeedbacks[resolvedProfileID]
    }

    func connectionValidationState(
        for providerID: APIProviderID,
        role: APIModelRole,
        profileID: UUID? = nil
    ) -> APIConnectionValidationState {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        return apiConnectionStates[resolvedProfileID]?[role] ?? .idle
    }

    func isValidatingConnections(for providerID: APIProviderID, profileID: UUID? = nil) -> Bool {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        return validatingProfileIDs.contains(resolvedProfileID)
    }

    func isFetchingRemoteModels(for providerID: APIProviderID, profileID: UUID? = nil) -> Bool {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        return fetchingRemoteModelProfileIDs.contains(resolvedProfileID)
    }

    func refreshRemoteModels(for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        guard supportsRemoteModelDiscovery(for: providerID) else {
            apiConnectionFeedbacks[resolvedProfileID] = nil
            return
        }
        apiFeedbacks[resolvedProfileID] = nil
        apiConnectionFeedbacks[resolvedProfileID] = nil

        do {
            _ = try persistDraft(for: providerID, profileID: resolvedProfileID)
        } catch {
            apiFeedbacks[resolvedProfileID] = .failure(error.localizedDescription)
            return
        }

        fetchingRemoteModelProfileIDs.insert(resolvedProfileID)
        Task {
            do {
                let models = try await apiConfigurationStore.refreshRemoteModels(
                    for: providerID,
                    profileID: resolvedProfileID
                )
                refreshAPIConfiguration(for: providerID)
                apiConnectionFeedbacks[resolvedProfileID] = .success(PalmiL10n.tr("manualLab.api.remoteModelsDetected", models.count))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                apiConnectionFeedbacks[resolvedProfileID] = .failure(message)
            }
            fetchingRemoteModelProfileIDs.remove(resolvedProfileID)
        }
    }

    func validateConnections(for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        let provider = snapshot(for: providerID).provider
        let roles = provider.editableModelRoles.isEmpty
            ? [APIModelRole.reasoningModel, .multimodalModel]
            : provider.editableModelRoles
        apiFeedbacks[resolvedProfileID] = nil
        apiConnectionFeedbacks[resolvedProfileID] = nil

        do {
            _ = try persistDraft(for: providerID, profileID: resolvedProfileID)
        } catch {
            apiFeedbacks[resolvedProfileID] = .failure(error.localizedDescription)
            resetConnectionValidation(for: resolvedProfileID)
            return
        }

        validatingProfileIDs.insert(resolvedProfileID)

        var states: [APIModelRole: APIConnectionValidationState] = [:]
        roles.forEach { states[$0] = .validating }
        apiConnectionStates[resolvedProfileID] = states

        Task {
            var failures: [String] = []

            for role in roles {
                if selectedModel(
                    for: providerID,
                    role: role,
                    profileID: resolvedProfileID
                ).id == APIModelSelection.noneMultimodalID {
                    apiConnectionStates[resolvedProfileID, default: [:]][role] = .success
                    continue
                }
                do {
                    _ = try await apiConnectionValidationService.validateConnection(
                        providerID: providerID,
                        profileID: resolvedProfileID,
                        role: role
                    )
                    apiConnectionStates[resolvedProfileID, default: [:]][role] = .success
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    apiConnectionStates[resolvedProfileID, default: [:]][role] = .failure(message)
                    failures.append("\(role.title)：\(message)")
                }
            }

            validatingProfileIDs.remove(resolvedProfileID)
            if failures.isEmpty {
                apiConnectionFeedbacks[resolvedProfileID] = .success(PalmiL10n.tr("manualLab.api.validationCompleted"))
            } else {
                apiConnectionFeedbacks[resolvedProfileID] = .failure(failures.joined(separator: "\n"))
            }
        }
    }

    func saveAPIConfiguration(for providerID: APIProviderID) {
        saveAPIConfiguration(for: providerID, profileID: nil)
    }

    func saveAPIConfiguration(for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)

        do {
            let snapshot = try persistDraft(for: providerID, profileID: resolvedProfileID)
            setActiveProviderID(providerID)
            apiFeedbacks[resolvedProfileID] = .success(PalmiL10n.tr("manualLab.api.profileSaved", snapshot.profileName))
        } catch {
            apiFeedbacks[resolvedProfileID] = .failure(error.localizedDescription)
        }
    }

    func clearAPIKey(for providerID: APIProviderID) {
        clearAPIKey(for: providerID, profileID: nil)
    }

    func clearAPIKey(for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)

        do {
            try apiConfigurationStore.clearAPIKey(for: providerID, profileID: resolvedProfileID)
            refreshAPIConfiguration(for: providerID)
            if var draft = apiDrafts[resolvedProfileID] {
                draft.apiKeyDraft = ""
                apiDrafts[resolvedProfileID] = draft
            }
            apiFeedbacks[resolvedProfileID] = .success(PalmiL10n.tr("manualLab.api.apiKeyCleared"))
            resetConnectionValidation(for: resolvedProfileID)
        } catch {
            apiFeedbacks[resolvedProfileID] = .failure(error.localizedDescription)
        }
    }

    private func appendCallbackResult(for actionID: ToolActionID, summary: String, details: String, status: ToolResult.Status) {
        guard let action = actions.first(where: { $0.id == actionID }) else { return }
        let result = ToolResult(status: status, title: action.localizedTitleForUI, summary: summary, details: details, actionID: actionID, createdAt: .now)
        lastResult = result
        executionLog.insert(.init(action: action, result: result), at: 0)
        workspaceStore.refreshCurrentThreadContents()
    }

    private func applyExecutionOutcome(_ outcome: ToolExecutionOutcome, for action: ToolAction) {
        lastResult = outcome.result
        executionLog.insert(.init(action: action, result: outcome.result), at: 0)
        if let presentation = outcome.presentation {
            self.presentation = presentation
        }
        if let shareURL = outcome.shareURL {
            self.sharePayload = SharePayload(url: shareURL)
        }
        workspaceStore.refreshCurrentThreadContents()
    }

    private func refreshAPIConfiguration() {
        APIProviderID.allCases.forEach(refreshAPIConfiguration(for:))
    }

    private func refreshAPIConfiguration(for providerID: APIProviderID) {
        let snapshot = apiConfigurationStore.snapshot(for: providerID)
        let profiles = apiConfigurationStore.profiles(for: providerID)
        apiSnapshots[providerID] = snapshot
        apiProfiles[providerID] = profiles

        let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        for profile in profiles {
            if var draft = apiDrafts[profile.id] {
                draft.profileName = profile.profileName
                draft.selectedAccessModeID = profile.selectedAccessMode.id
                draft.defaultModelID = profile.defaultModelSelectionID
                draft.reasoningModelID = profile.reasoningModelSelectionID
                draft.multimodalModelID = profile.multimodalModelSelectionID
                draft.lightweightModelID = profile.lightweightModelSelectionID
                draft.customBaseURLDraft = profile.customBaseURLString
                draft.selectedLMStudioServer = profile.selectedServer
                if let savedAPIKey = apiConfigurationStore.apiKey(for: providerID, profileID: profile.id),
                   !savedAPIKey.isEmpty {
                    draft.apiKeyDraft = savedAPIKey
                } else if !profile.hasAPIKey {
                    draft.apiKeyDraft = ""
                }
                apiDrafts[profile.id] = draft
            }
        }

        let staleDraftIDs = Set(
            apiDrafts.values
                .filter { $0.providerID == providerID && profileByID[$0.profileID] == nil }
                .map(\.profileID)
        )
        for staleDraftID in staleDraftIDs {
            apiDrafts.removeValue(forKey: staleDraftID)
            apiFeedbacks.removeValue(forKey: staleDraftID)
            apiConnectionFeedbacks.removeValue(forKey: staleDraftID)
            apiConnectionStates.removeValue(forKey: staleDraftID)
            lmStudioDiscoveredServers.removeValue(forKey: staleDraftID)
            discoveringLMStudioProfileIDs.remove(staleDraftID)
            validatingProfileIDs.remove(staleDraftID)
            fetchingRemoteModelProfileIDs.remove(staleDraftID)
        }
    }

    private func persistDraft(
        for providerID: APIProviderID,
        profileID: UUID
    ) throws -> APIConfigurationProfileSnapshot {
        let draft = draftState(for: providerID, profileID: profileID)

        try apiConfigurationStore.saveConfiguration(
            profileName: draft.profileName,
            apiKey: draft.apiKeyDraft,
            selectedAccessModeID: draft.selectedAccessModeID,
            defaultModelID: draft.defaultModelID,
            reasoningModelID: draft.reasoningModelID,
            multimodalModelID: draft.multimodalModelID,
            lightweightModelID: draft.lightweightModelID,
            customBaseURLString: draft.customBaseURLDraft,
            selectedServer: draft.selectedLMStudioServer,
            for: providerID,
            profileID: profileID
        )
        refreshAPIConfiguration(for: providerID)

        guard let refreshedProfile = profiles(for: providerID).first(where: { $0.id == profileID }) else {
            throw AppError.invalidState(PalmiL10n.tr("manualLab.api.refreshAfterSaveFailed"))
        }

        return refreshedProfile
    }

    private func resolvedProfileID(for providerID: APIProviderID, profileID: UUID?) -> UUID {
        profileID ?? snapshot(for: providerID).profileID
    }

    private func draftState(for providerID: APIProviderID, profileID: UUID? = nil) -> APIProfileDraftState {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        if let draft = apiDrafts[resolvedProfileID] {
            return draft
        }

        let profile = profiles(for: providerID).first(where: { $0.id == resolvedProfileID }) ?? profiles(for: providerID)[0]
        let draft = APIProfileDraftState(
            providerID: providerID,
            profileID: resolvedProfileID,
            profileName: profile.profileName,
            selectedAccessModeID: profile.selectedAccessMode.id,
            defaultModelID: profile.defaultModelSelectionID,
            reasoningModelID: profile.reasoningModelSelectionID,
            multimodalModelID: profile.multimodalModelSelectionID,
            lightweightModelID: profile.lightweightModelSelectionID,
            apiKeyDraft: apiConfigurationStore.apiKey(for: providerID, profileID: resolvedProfileID) ?? "",
            customBaseURLDraft: profile.customBaseURLString,
            selectedLMStudioServer: profile.selectedServer
        )
        apiDrafts[resolvedProfileID] = draft
        return draft
    }

    private func validModelID(
        currentModelID: String,
        for provider: APIProviderDefinition,
        for accessMode: APIAccessModeDefinition,
        role: APIModelRole
    ) -> String {
        let availableModels: [APIModelDefinition]
        if provider.supportsManualModelSelection {
            availableModels = accessMode.availableModels(for: role)
        } else {
            availableModels = [APIModelDefinition.automatic(for: role)]
        }

        if availableModels.contains(where: { $0.id == currentModelID }) {
            return currentModelID
        }
        let trimmedCurrentModelID = currentModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.supportsManualModelSelection,
           accessMode.models.isEmpty,
           !trimmedCurrentModelID.isEmpty,
           trimmedCurrentModelID != APIModelSelection.automaticID,
           trimmedCurrentModelID != APIModelSelection.noneMultimodalID {
            return trimmedCurrentModelID
        }
        if provider.supportsManualModelSelection, role == .defaultModel {
            return accessMode.defaultModel.id
        }
        if provider.supportsManualModelSelection, role == .multimodalModel {
            return accessMode.defaultModel(for: .multimodalModel).id
        }
        return APIModelSelection.automaticID
    }

    private func resolveSelectedModel(
        _ selectionID: String,
        role: APIModelRole,
        provider: APIProviderDefinition,
        accessMode: APIAccessModeDefinition,
        defaultModel: APIModelDefinition
    ) -> APIModelDefinition {
        if selectionID == APIModelSelection.automaticID || !provider.supportsManualModelSelection {
            switch role {
            case .defaultModel:
                return accessMode.defaultModel
            case .multimodalModel:
                return accessMode.defaultModel(for: .multimodalModel)
            case .reasoningModel, .lightweightModel:
                return defaultModel
            }
        }
        let trimmed = selectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.supportsManualModelSelection,
           accessMode.models.isEmpty,
           !trimmed.isEmpty,
           trimmed != APIModelSelection.automaticID,
           trimmed != APIModelSelection.noneMultimodalID {
            return APIModelDefinition(id: trimmed, title: trimmed, summary: "")
        }
        return accessMode.model(withID: selectionID) ?? accessMode.defaultModel(for: role)
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func prioritizedLMStudioCandidateURLs(for providerID: APIProviderID, profileID: UUID) -> [URL] {
        let draft = draftState(for: providerID, profileID: profileID)
        let savedProfiles = profiles(for: providerID)
        var orderedCandidates: [String] = []

        func append(_ rawValue: String?) {
            guard let rawValue = nonEmpty(rawValue) else { return }
            orderedCandidates.append(rawValue)
        }

        append(draft.customBaseURLDraft)
        append(draft.selectedLMStudioServer?.baseURLString)

        for server in lmStudioDiscoveredServers[profileID] ?? [] {
            append(server.baseURLString)
        }

        for profile in savedProfiles {
            append(profile.customBaseURLString)
            append(profile.endpointURL?.absoluteString)
            append(profile.selectedServer?.baseURLString)
        }

        var seen: Set<String> = []
        var urls: [URL] = []
        for rawValue in orderedCandidates {
            guard let url = normalizedLMStudioCandidateURL(from: rawValue) else { continue }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    private func normalizedLMStudioCandidateURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var url = URL(string: candidate) else {
            return nil
        }

        let normalizedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.isEmpty {
            url.appendPathComponent("v1")
        }

        return url
    }

    private func resolveAutoConfiguredLMStudioSelection(
        candidateURLs: [URL],
        apiToken: String?
    ) async -> (
        selectedServer: LMStudioDiscoveredServer?,
        discoveredServers: [LMStudioDiscoveredServer],
        lastError: Error?
    ) {
        var discoveredByID: [String: LMStudioDiscoveredServer] = [:]
        var lastError: Error?

        for candidateURL in candidateURLs {
            do {
                let server = try await lmStudioDiscoveryService.refreshServer(
                    baseURL: candidateURL,
                    apiToken: apiToken
                )
                discoveredByID[server.id] = server
                return (
                    selectedServer: server,
                    discoveredServers: sortLMStudioServers(Array(discoveredByID.values)),
                    lastError: nil
                )
            } catch {
                lastError = error
            }
        }

        let scannedServers = await lmStudioDiscoveryService.discoverServers()
        for server in scannedServers {
            discoveredByID[server.id] = server
        }

        guard var selectedServer = scannedServers.first else {
            return (
                selectedServer: nil,
                discoveredServers: sortLMStudioServers(Array(discoveredByID.values)),
                lastError: lastError
            )
        }

        if let apiToken,
           let baseURL = selectedServer.baseURL,
           let refreshedServer = try? await lmStudioDiscoveryService.refreshServer(
                baseURL: baseURL,
                apiToken: apiToken
           ) {
            selectedServer = refreshedServer
            discoveredByID[refreshedServer.id] = refreshedServer
        }

        return (
            selectedServer: selectedServer,
            discoveredServers: sortLMStudioServers(Array(discoveredByID.values)),
            lastError: nil
        )
    }

    private func validateAutoConfiguredLMStudioConnection(
        for providerID: APIProviderID,
        profileID: UUID
    ) async -> Bool {
        validatingProfileIDs.insert(profileID)
        apiConnectionStates[profileID] = [.reasoningModel: .validating]
        apiConnectionFeedbacks[profileID] = nil

        defer {
            validatingProfileIDs.remove(profileID)
        }

        do {
            _ = try await apiConnectionValidationService.validateConnection(
                providerID: providerID,
                profileID: profileID,
                role: .reasoningModel
            )
            apiConnectionStates[profileID] = [.reasoningModel: .success]
            apiConnectionFeedbacks[profileID] = .success(PalmiL10n.tr("manualLab.api.validationCompleted"))
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            apiConnectionStates[profileID] = [.reasoningModel: .failure(message)]
            apiConnectionFeedbacks[profileID] = .failure(message)
            return false
        }
    }

    private func sortLMStudioServers(_ servers: [LMStudioDiscoveredServer]) -> [LMStudioDiscoveredServer] {
        servers.sorted { lhs, rhs in
            if lhs.requiresAuthentication != rhs.requiresAuthentication {
                return rhs.requiresAuthentication
            }
            if (lhs.selectedModelID != nil) != (rhs.selectedModelID != nil) {
                return lhs.selectedModelID != nil
            }
            if lhs.modelCount != rhs.modelCount {
                return lhs.modelCount > rhs.modelCount
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func resetConnectionValidation(for profileID: UUID) {
        validatingProfileIDs.remove(profileID)
        apiConnectionStates.removeValue(forKey: profileID)
        apiConnectionFeedbacks.removeValue(forKey: profileID)
    }
}
