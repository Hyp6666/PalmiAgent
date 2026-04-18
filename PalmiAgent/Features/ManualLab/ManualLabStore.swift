import Observation
import UIKit

struct SharePayload: Identifiable {
    let url: URL
    var id: String { url.path }
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
}

@MainActor
@Observable
final class ManualLabStore {
    let actions: [ToolAction]
    let executor: ActionExecutor
    let apiConfigurationStore: APIConfigurationStore
    let llmToolCallingService: LLMToolCallingService
    let apiConnectionValidationService: APIConnectionValidationService
    let workspaceStore: WorkspaceStore
    let toolPermissionStore: ToolPermissionStore

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

    init(
        actions: [ToolAction],
        executor: ActionExecutor,
        apiConfigurationStore: APIConfigurationStore,
        llmToolCallingService: LLMToolCallingService,
        apiConnectionValidationService: APIConnectionValidationService,
        workspaceStore: WorkspaceStore,
        toolPermissionStore: ToolPermissionStore
    ) {
        self.actions = actions
        self.executor = executor
        self.apiConfigurationStore = apiConfigurationStore
        self.llmToolCallingService = llmToolCallingService
        self.apiConnectionValidationService = apiConnectionValidationService
        self.workspaceStore = workspaceStore
        self.toolPermissionStore = toolPermissionStore
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

    var activeLLMSnapshot: APIProviderConfigurationSnapshot {
        snapshot(for: .glm)
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
            details = "已得到图片：\(Int(image.size.width)) x \(Int(image.size.height))"
            status = .success
        } else {
            details = "用户取消了图片选择。"
            status = .warning
        }
        appendCallbackResult(for: presentation.actionID, summary: "媒体回调已完成", details: details, status: status)
        self.presentation = nil
    }

    func handleDocumentScan(_ pageCount: Int?) {
        guard let presentation else { return }
        let details = pageCount.map { "扫描完成，共 \($0) 页。" } ?? "用户取消了扫描。"
        appendCallbackResult(for: presentation.actionID, summary: "文档扫描回调已完成", details: details, status: pageCount == nil ? .warning : .success)
        self.presentation = nil
    }

    func handleTextScan(_ text: String?) {
        guard let presentation else { return }
        let details = text.map { "识别结果：\($0)" } ?? "没有识别到文本，或者用户取消了扫描。"
        appendCallbackResult(for: presentation.actionID, summary: "实时文本扫描已回传", details: details, status: text == nil ? .warning : .success)
        self.presentation = nil
    }

    func dismissPresentation() {
        presentation = nil
    }

    func runNaturalLanguageToolCall() {
        let trimmedPrompt = naturalLanguagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            llmStatusMessage = "请输入一条自然语言指令。"
            return
        }

        isRunningNaturalLanguageCall = true
        llmStatusMessage = nil
        llmStreamingPreview = nil

        Task {
            do {
                let session = try await llmToolCallingService.runSession(
                    prompt: trimmedPrompt,
                    providerID: .glm,
                    actions: enabledActions,
                    onEvent: { event in
                        switch event {
                        case .planningReceived(_, let tokens):
                            self.llmStatusMessage = "规划完成，已用 \(tokens) tokens"
                        case .toolStarted:
                            self.llmStreamingPreview = nil
                            self.llmStatusMessage = "正在执行工具…"
                        case .toolFinished:
                            self.llmStatusMessage = "工具执行完成，正在生成总结…"
                        case .streamingDelta(let text):
                            self.llmStreamingPreview = (self.llmStreamingPreview ?? "") + text
                        case .tokenUpdate(let tokens):
                            self.llmStatusMessage = "正在生成总结，已用 \(tokens) tokens"
                        case .finalReplyReceived(_, let tokens):
                            self.llmStatusMessage = "模型已完成，共 \(tokens) tokens"
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
        selectedAccessMode(for: providerID, profileID: profileID).availableModels(for: role)
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
        return activeSnapshot.provider.accessMode(withID: selectedAccessModeID(for: providerID, profileID: profileID)) ?? activeSnapshot.selectedAccessMode
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
            for: accessMode,
            role: .defaultModel
        )
        draft.reasoningModelID = validModelID(
            currentModelID: draft.reasoningModelID,
            for: accessMode,
            role: .reasoningModel
        )
        draft.multimodalModelID = validModelID(
            currentModelID: draft.multimodalModelID,
            for: accessMode,
            role: .multimodalModel
        )
        draft.lightweightModelID = validModelID(
            currentModelID: draft.lightweightModelID,
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
        let accessMode = selectedAccessMode(for: providerID, profileID: profileID)
        let resolvedDefaultModel = resolveSelectedModel(
            selectedModelID(for: providerID, role: .defaultModel, profileID: profileID),
            role: .defaultModel,
            accessMode: accessMode,
            defaultModel: accessMode.defaultModel
        )
        return resolveSelectedModel(
            selectedModelID(for: providerID, role: role, profileID: profileID),
            role: role,
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

    func validateConnections(for providerID: APIProviderID, profileID: UUID? = nil) {
        let resolvedProfileID = resolvedProfileID(for: providerID, profileID: profileID)
        validatingProfileIDs.insert(resolvedProfileID)
        apiConnectionFeedbacks[resolvedProfileID] = nil

        var states: [APIModelRole: APIConnectionValidationState] = [:]
        APIModelRole.allCases.forEach { states[$0] = .validating }
        apiConnectionStates[resolvedProfileID] = states

        Task {
            var failures: [String] = []

            for role in APIModelRole.allCases {
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
                apiConnectionFeedbacks[resolvedProfileID] = .success("联通验证完成。")
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
        let draft = draftState(for: providerID, profileID: resolvedProfileID)

        do {
            try apiConfigurationStore.saveConfiguration(
                profileName: draft.profileName,
                apiKey: draft.apiKeyDraft,
                selectedAccessModeID: draft.selectedAccessModeID,
                defaultModelID: draft.defaultModelID,
                reasoningModelID: draft.reasoningModelID,
                multimodalModelID: draft.multimodalModelID,
                lightweightModelID: draft.lightweightModelID,
                for: providerID,
                profileID: resolvedProfileID
            )
            refreshAPIConfiguration(for: providerID)
            let snapshot = snapshot(for: providerID)
            apiFeedbacks[resolvedProfileID] = .success("\(snapshot.profileName) 已保存。")
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
            apiFeedbacks[resolvedProfileID] = .success("API Key 已清空。")
            resetConnectionValidation(for: resolvedProfileID)
        } catch {
            apiFeedbacks[resolvedProfileID] = .failure(error.localizedDescription)
        }
    }

    private func appendCallbackResult(for actionID: ToolActionID, summary: String, details: String, status: ToolResult.Status) {
        guard let action = actions.first(where: { $0.id == actionID }) else { return }
        let result = ToolResult(status: status, title: action.title, summary: summary, details: details, actionID: actionID, createdAt: .now)
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
                if let savedAPIKey = apiConfigurationStore.apiKey(for: providerID, profileID: profile.id),
                   !savedAPIKey.isEmpty {
                    draft.apiKeyDraft = savedAPIKey
                } else if !profile.hasAPIKey {
                    draft.apiKeyDraft = ""
                }
                apiDrafts[profile.id] = draft
            }
        }

        let staleDraftIDs = Set(apiDrafts.keys).subtracting(profileByID.keys)
        for staleDraftID in staleDraftIDs {
            apiDrafts.removeValue(forKey: staleDraftID)
            apiFeedbacks.removeValue(forKey: staleDraftID)
        }
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
            apiKeyDraft: apiConfigurationStore.apiKey(for: providerID, profileID: resolvedProfileID) ?? ""
        )
        apiDrafts[resolvedProfileID] = draft
        return draft
    }

    private func validModelID(
        currentModelID: String,
        for accessMode: APIAccessModeDefinition,
        role: APIModelRole
    ) -> String {
        accessMode.availableModels(for: role).contains(where: { $0.id == currentModelID })
            ? currentModelID
            : accessMode.defaultModel(for: role).id
    }

    private func resolveSelectedModel(
        _ selectionID: String,
        role: APIModelRole,
        accessMode: APIAccessModeDefinition,
        defaultModel: APIModelDefinition
    ) -> APIModelDefinition {
        if selectionID == APIModelSelection.automaticID {
            return role == .defaultModel ? accessMode.defaultModel : defaultModel
        }
        return accessMode.model(withID: selectionID) ?? accessMode.defaultModel(for: role)
    }

    private func resetConnectionValidation(for profileID: UUID) {
        validatingProfileIDs.remove(profileID)
        apiConnectionStates.removeValue(forKey: profileID)
        apiConnectionFeedbacks.removeValue(forKey: profileID)
    }
}
