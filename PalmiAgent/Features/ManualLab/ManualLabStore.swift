import Observation
import UIKit

struct SharePayload: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 设置与工具实验页的共同后端入口。模型配置唯一事实源是模型库，这里不保存任何副本。
@MainActor
@Observable
final class ManualLabStore {
    let actions: [ToolAction]
    let executor: ActionExecutor
    let modelLibrary: ModelLibraryStore
    let modelRuntime: any AgentModelRuntime
    let remoteWebSearchService: RemoteWebSearchService
    let webCapabilityService: WebCapabilityService
    let workspaceStore: WorkspaceStore
    let toolPermissionStore: ToolPermissionStore
    let toolAuthorizationStore: ToolAuthorizationStore

    var lastResult: ToolResult?
    var executionLog: [ToolExecutionRecord] = []
    var runningActionID: ToolActionID?
    var presentation: MediaPresentation?
    var sharePayload: SharePayload?

    init(
        actions: [ToolAction],
        executor: ActionExecutor,
        modelLibrary: ModelLibraryStore,
        modelRuntime: any AgentModelRuntime,
        remoteWebSearchService: RemoteWebSearchService,
        webCapabilityService: WebCapabilityService,
        workspaceStore: WorkspaceStore,
        toolPermissionStore: ToolPermissionStore,
        toolAuthorizationStore: ToolAuthorizationStore
    ) {
        self.actions = actions
        self.executor = executor
        self.modelLibrary = modelLibrary
        self.modelRuntime = modelRuntime
        self.remoteWebSearchService = remoteWebSearchService
        self.webCapabilityService = webCapabilityService
        self.workspaceStore = workspaceStore
        self.toolPermissionStore = toolPermissionStore
        self.toolAuthorizationStore = toolAuthorizationStore
    }

    var groupedActions: [(category: ToolCategory, actions: [ToolAction])] {
        ActionCatalog.grouped()
    }

    var exposedToolCount: Int {
        toolPermissionStore.enabledActionCount(in: actions)
    }

    var enabledActions: [ToolAction] {
        toolPermissionStore.enabledActions(from: actions)
    }

    func restoreFactoryStateAfterPreferencesReset() {
        modelLibrary.reconcileAllSources()
    }

    func run(_ action: ToolAction) {
        runningActionID = action.id
        Task {
            defer { self.runningActionID = nil }
            do {
                let outcome = try await executor.execute(action, arguments: .empty)
                self.applyExecutionOutcome(outcome, for: action)
            } catch is CancellationError {
                return
            } catch {
                self.appendCallbackResult(
                    for: action.id,
                    summary: "执行失败",
                    details: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                    status: .failure
                )
            }
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
}
