import Foundation

struct BionicProfessionalRequest: Sendable {
    let role: BionicRole
    let binding: BionicObject
    let task: String
    let workspaceID: String?
    let operationID: String
    let stepID: String
    let maximumResultTokens: Int

    init(role: BionicRole, binding: BionicObject, task: String, workspaceID: String?,
         operationID: String, stepID: String, maximumResultTokens: Int = 2000) {
        self.role = role
        self.binding = binding
        self.task = task
        self.workspaceID = workspaceID
        self.operationID = operationID
        self.stepID = stepID
        self.maximumResultTokens = maximumResultTokens
    }
}

struct BionicProfessionalResult: Sendable {
    let text: String
    let approvalRequired: Bool
    let truncated: Bool

    init(text: String, approvalRequired: Bool = false, truncated: Bool = false) {
        self.text = text
        self.approvalRequired = approvalRequired
        self.truncated = truncated
    }
}

@MainActor
protocol BionicProfessionalExecuting {
    func workspaceCatalog(for role: BionicRole) throws -> [BionicObject]
    func execute(_ request: BionicProfessionalRequest) async throws -> BionicProfessionalResult
}

nonisolated enum BionicProfessionalPolicy {
    static func canUseUserWorkspaces(_ role: BionicRole) -> Bool {
        role.installationID == BionicSystemPersona.installationID
            && role.characterID == BionicSystemPersona.characterID
    }

    static func allowedActionIDs(for role: BionicRole) -> Set<ToolActionID> {
        let textTools: Set<ToolActionID> = [
            .searchWeb, .fetchStaticWebPage, .getCurrentDateTime,
            .fileRead, .listDirectory, .fileWrite, .fileAppend
        ]
        guard canUseUserWorkspaces(role) else { return textTools }
        return textTools.union([.breakDownFile, .fileManage, .runPython])
    }

    static let runLimits = AgentRunLimits(
        maximumIterations: 8,
        maximumToolCalls: 16,
        maximumElapsedNanoseconds: 90 * 1_000_000_000
    )

    @MainActor static func finalText(turn: AgentTurnResult, session: AgentSession) -> String? {
        guard let message = session.messages.last, message.role == .assistant,
              message.toolUses.isEmpty else { return nil }
        let text = LLMGuardrails.sanitizeUserFacingReply(
            message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !text.isEmpty, text == turn.finalReply.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let visible = text.replacingOccurrences(of: #"(?is)<(think|thinking)>.*?</\1>"#,
            with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty,
              visible.range(of: #"(?i)</?(?:think|thinking)>"#, options: .regularExpression) == nil else {
            return nil
        }
        return visible
    }
}

/// A fresh professional loop whose only externally returned content is its final answer.
@MainActor
final class BionicProfessionalExecutor: BionicProfessionalExecuting {
    private let workspaceManager: WorkspaceManager
    private let modelPlans: ModelPlanStore
    private let permissions: ToolPermissionStore
    private let archive: BionicArchiveStore
    private let makeAgentLoop: @MainActor (SkillRegistry) -> AgentLoop
    private let prepareRuntime: @MainActor () -> Void

    init(
        workspaceManager: WorkspaceManager,
        modelPlans: ModelPlanStore,
        permissions: ToolPermissionStore,
        archive: BionicArchiveStore,
        prepareRuntime: @escaping @MainActor () -> Void = {},
        makeAgentLoop: @escaping @MainActor (SkillRegistry) -> AgentLoop
    ) {
        self.workspaceManager = workspaceManager
        self.modelPlans = modelPlans
        self.permissions = permissions
        self.archive = archive
        self.prepareRuntime = prepareRuntime
        self.makeAgentLoop = makeAgentLoop
    }

    func workspaceCatalog(for role: BionicRole) throws -> [BionicObject] {
        guard BionicProfessionalPolicy.canUseUserWorkspaces(role) else { return [] }
        return try workspaceManager.listProjects(on: .professional).map {
            ["workspace_id": .string($0.id.uuidString.lowercased()), "name": .string($0.name)]
        }
    }

    func execute(_ request: BionicProfessionalRequest) async throws -> BionicProfessionalResult {
        try Task.checkCancellation()
        let task = request.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, task.count <= 4000, request.maximumResultTokens > 0,
              BionicCodec.validID(request.role.installationID),
              BionicCodec.validID(request.operationID),
              !request.stepID.isEmpty,
              request.stepID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw BionicFailure("invalidFields", detail: "professional request")
        }
        let workspaceRoot = try authorizedWorkspace(for: request)
        let fingerprint = try BionicCodec.sha(BionicCodec.encode(.object([
            "task": .string(task), "workspace_id": .text(request.workspaceID),
            "character_id": .string(request.role.characterID), "binding": .object(request.binding)
        ])))
        let receipt = archive.localURL(request.role.installationID)
            .appendingPathComponent("professional_runs", isDirectory: true)
            .appendingPathComponent(request.operationID + "_" + request.stepID, isDirectory: true)
        if FileManager.default.fileExists(atPath: receipt.appendingPathComponent("result.json").path) {
            let saved = try BionicDisk.read(receipt, "result.json")
            guard saved.text("fingerprint") == fingerprint else {
                throw BionicFailure("invalidFields", detail: "professional receipt mismatch")
            }
            return BionicProfessionalResult(text: saved.text("text"),
                approvalRequired: saved.flag("approval_required"))
        }
        // A started run without a receipt may already have changed a user's files.
        // Never automatically repeat an operation whose outcome is unknown.
        guard !FileManager.default.fileExists(atPath: receipt.appendingPathComponent("started.json").path) else {
            throw BionicFailure("professionalExecutionInterrupted",
                detail: "上次专业执行未确认完成，已避免重复执行。")
        }
        let binding = ModelPlanSessionOverride(
            planID: request.binding.optionalText("plan_id").flatMap(UUID.init(uuidString:)),
            primaryCandidateID: request.binding.optionalText("primary_candidate_id").flatMap(UUID.init(uuidString:)),
            multimodalCandidateID: request.binding.optionalText("multimodal_candidate_id").flatMap(UUID.init(uuidString:)),
            lightweightCandidateID: request.binding.optionalText("lightweight_candidate_id").flatMap(UUID.init(uuidString:))
        )
        let overrides = modelPlans.roleOverrides(for: binding)
        guard let providerID = overrides.primaryProviderID else { throw BionicFailure("primaryMissing") }
        let allowed = BionicProfessionalPolicy.allowedActionIDs(for: request.role)
        let actions = permissions.enabledActions(from: ActionCatalog.all).filter {
            allowed.contains($0.id) && (workspaceRoot != nil || $0.id != .runPython)
        }
        // Shared dependencies must initialize before entering a temporary storage scope.
        prepareRuntime()
        let receiptPath = "professional_runs/" + request.operationID + "_" + request.stepID
        try await archive.saveProfessionalReceipt(request.role.installationID,
            path: receiptPath + "/started.json", object: ["fingerprint": .string(fingerprint)])
        try Task.checkCancellation()
        let result = try await workspaceManager.withTemporaryProfessionalWorkspace(using: workspaceRoot) {
            // This registry sees bundled skills and an empty temporary import store,
            // never another user's workspace or globally imported skill contents.
            let skills = SkillRegistry(workspaceManager: workspaceManager)
            let loop = makeAgentLoop(skills)
            var approvalRequired = false
            let observer = Task { @MainActor in
                for await event in loop.events {
                    if case .approvalRequested(let approval) = event {
                        approvalRequired = true
                        // Manual approval has no hidden UI. Existing automatic review
                        // and allow-all policies are handled by AgentLoop itself.
                        loop.resolveApprovalRequest(approval.id, approved: false)
                    }
                }
            }
            defer { observer.cancel() }
            let instructions = """
            这是角色委托的一次独立专业任务。仅用当前工具完成范围明确的检索、核实、分析或文件处理；超出工具能力或需要长期复杂执行时说明限制。
            最终只返回可用结果、必要证据及实际未完成部分，不含思考、进度、执行日志或角色扮演。仅以文本交付；临时文件只辅助处理，不声称交付可下载文件，不返回临时或设备绝对路径。
            最终结果尽量控制在约\(request.maximumResultTokens) tokens以内，优先交付核心结论与来源。
            \(workspaceRoot == nil ? "本次无权访问用户现有工作区。" : "当前文件根是宿主指定的用户工作区；实际文件修改保留在此工作区，最终说明修改的相对路径。")

            任务：
            \(task)
            """
            let turn = try await loop.runTurn(userInput: instructions, providerID: providerID,
                actions: actions, modelOverrides: overrides, runLimits: BionicProfessionalPolicy.runLimits)
            try Task.checkCancellation()
            guard let final = BionicProfessionalPolicy.finalText(turn: turn,
                session: loop.currentSessionSnapshot()) else {
                throw BionicFailure("professionalFinalResultUnavailable",
                    detail: "专业执行未生成可交付结论。")
            }
            return BionicProfessionalResult(text: final, approvalRequired: approvalRequired)
        }
        try Task.checkCancellation()
        try await archive.saveProfessionalReceipt(request.role.installationID,
            path: receiptPath + "/result.json", object: ["fingerprint": .string(fingerprint),
                "text": .string(result.text), "approval_required": .bool(result.approvalRequired)])
        try Task.checkCancellation()
        return result
    }

    private func authorizedWorkspace(for request: BionicProfessionalRequest) throws -> URL? {
        guard let id = request.workspaceID else { return nil }
        guard BionicProfessionalPolicy.canUseUserWorkspaces(request.role),
              let projectID = UUID(uuidString: id),
              try workspaceManager.listProjects(on: .professional).contains(where: { $0.id == projectID }) else {
            throw BionicFailure("professionalWorkspaceDenied", detail: "该角色无权使用指定工作区。")
        }
        return try workspaceManager.withProject(projectID) {
            try workspaceManager.ensureWorkspace()
        }
    }
}

extension BionicArchiveStore {
    /// Serialize receipt persistence with role deletion; deleted roles cannot be recreated.
    func saveProfessionalReceipt(_ instance: String, path: String, object: BionicObject) throws {
        _ = try loadRole(instance)
        try BionicDisk.write(localURL(instance), path, object)
    }
}
