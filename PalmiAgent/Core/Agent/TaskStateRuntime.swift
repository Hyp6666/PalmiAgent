import Foundation

@MainActor
final class TaskStateRuntime {
    private let fileStore: TaskStateFileStore
    private let decoder = JSONDecoder()

    private var updatesThisTurn = 0
    private var noOpsThisTurn = 0
    private var lastMutationWasTaskUpdate = false

    init(fileStore: TaskStateFileStore) {
        self.fileStore = fileStore
    }

    func beginTurn() {
        updatesThisTurn = 0
        noOpsThisTurn = 0
        lastMutationWasTaskUpdate = false
    }

    func recordNonTaskProgress() {
        lastMutationWasTaskUpdate = false
    }

    func loadSnapshot(
        identity: AgentTaskStateIdentity,
        fallback: AgentTaskStateSnapshot?
    ) -> AgentTaskStateSnapshot {
        do {
            return try fileStore.loadSnapshot(identity: identity, fallback: fallback)
        } catch {
            return AgentTaskStateSnapshot(
                projectID: identity.projectID,
                threadID: identity.threadID,
                sessionID: identity.sessionID,
                currentRunID: nil,
                currentState: nil,
                recentRuns: [],
                unavailableReason: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                updatedAt: .now
            )
        }
    }

    func handleUpdateTool(
        input: String,
        identity: AgentTaskStateIdentity,
        snapshot: AgentTaskStateSnapshot?
    ) -> AgentTaskUpdateResult {
        guard updatesThisTurn < 3 else {
            return limitedResult(
                identity: identity,
                snapshot: snapshot,
                reason: "本轮任务更新次数已达到上限，请继续执行或直接收尾。"
            )
        }
        guard !lastMutationWasTaskUpdate else {
            return limitedResult(
                identity: identity,
                snapshot: snapshot,
                reason: "不能连续更新任务状态。请先推进实际执行或给出阶段性答复。"
            )
        }

        do {
            let args = try decoder.decode(UpdateTaskStateArgs.self, from: Data(input.utf8))
            let currentSnapshot = snapshot ?? AgentTaskStateSnapshot(
                projectID: identity.projectID,
                threadID: identity.threadID,
                sessionID: identity.sessionID,
                currentRunID: nil,
                currentState: nil,
                recentRuns: [],
                unavailableReason: nil,
                updatedAt: .now
            )
            let oldState = currentSnapshot.currentState
            let state = try makeState(
                args: args,
                identity: identity,
                existingState: oldState
            )
            let isNoOp = oldState.map { equivalent(lhs: $0, rhs: state) } ?? false
            if isNoOp {
                guard noOpsThisTurn < 1 else {
                    return limitedResult(
                        identity: identity,
                        snapshot: snapshot,
                        reason: "本轮任务状态没有实质变化，已停止重复更新。"
                    )
                }
                noOpsThisTurn += 1
            }

            updatesThisTurn += 1
            lastMutationWasTaskUpdate = true
            let savedSnapshot = try fileStore.save(state: state, reason: normalized(args.reason, limit: 120))
            return AgentTaskUpdateResult(
                state: state,
                snapshot: savedSnapshot,
                payload: successPayload(state: state, reason: args.reason, noOp: isNoOp),
                summary: "\(state.title)：\(state.completedCount)/\(state.totalCount)",
                isError: false,
                isNoOp: isNoOp
            )
        } catch {
            updatesThisTurn += 1
            lastMutationWasTaskUpdate = true
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let fallbackSnapshot = snapshot ?? AgentTaskStateSnapshot(
                projectID: identity.projectID,
                threadID: identity.threadID,
                sessionID: identity.sessionID,
                currentRunID: nil,
                currentState: nil,
                recentRuns: [],
                unavailableReason: nil,
                updatedAt: .now
            )
            return AgentTaskUpdateResult(
                state: fallbackSnapshot.currentState,
                snapshot: fallbackSnapshot,
                payload: errorPayload(message),
                summary: message,
                isError: true,
                isNoOp: false
            )
        }
    }

    private func makeState(
        args: UpdateTaskStateArgs,
        identity: AgentTaskStateIdentity,
        existingState: AgentTaskState?
    ) throws -> AgentTaskState {
        guard !args.items.isEmpty else {
            throw AppError.invalidState("任务列表不能为空。")
        }
        guard args.items.count <= 6 else {
            throw AppError.invalidState("任务最多只能有 6 项，请合并后重试。")
        }

        let now = Date()
        let shouldCreateNewRun = existingState == nil || existingState?.lifecycle.isActiveLike == false
        let taskRunID = shouldCreateNewRun ? UUID() : existingState!.taskRunID
        let oldItems = existingState?.items ?? []
        let oldItemsByID = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0) })
        var usedIDs: Set<String> = []
        var nextIDIndex = nextGeneratedIDIndex(from: oldItems)

        var items: [AgentTaskItem] = []
        for (index, input) in args.items.enumerated() {
            let candidateID = normalizedOptional(input.id)
                ?? (index < oldItems.count ? oldItems[index].id : nil)
                ?? nextID(usedIDs: usedIDs, nextIDIndex: &nextIDIndex)
            let id = uniqueID(candidateID, usedIDs: &usedIDs, nextIDIndex: &nextIDIndex)
            let previous = oldItemsByID[id]
            items.append(
                AgentTaskItem(
                    id: id,
                    title: normalized(input.title, limit: 48, fallback: previous?.title ?? "任务"),
                    status: input.status,
                    displaySummary: normalized(
                        input.displaySummary ?? previous?.displaySummary ?? input.title,
                        limit: 160,
                        fallback: previous?.displaySummary ?? input.title
                    ),
                    hiddenDetail: normalizedOptional(input.hiddenDetail) ?? previous?.hiddenDetail,
                    detailPath: previous?.detailPath,
                    acceptanceCriteria: normalizedList(input.acceptanceCriteria ?? previous?.acceptanceCriteria ?? [], limit: 4, itemLimit: 160),
                    evidenceReferences: evidenceReferences(
                        toolUseIDs: input.evidenceToolUseIDs,
                        previous: previous?.evidenceReferences ?? []
                    ),
                    createdAt: previous?.createdAt ?? now,
                    updatedAt: now
                )
            )
        }

        let missingCompleted = oldItems.filter { oldItem in
            oldItem.status.isTerminal && !items.contains(where: { $0.id == oldItem.id })
        }
        for oldItem in missingCompleted where items.count < 6 {
            items.append(oldItem)
            usedIDs.insert(oldItem.id)
        }

        normalizeInProgress(&items)
        let lifecycle = resolvedLifecycle(
            requested: args.lifecycle,
            items: items,
            existing: existingState?.lifecycle
        )
        let focusItemID = normalizedOptional(args.focusItemID)
            ?? items.first(where: { $0.status == .inProgress })?.id
            ?? items.first?.id

        return AgentTaskState(
            schemaVersion: 1,
            id: existingState?.id ?? UUID(),
            projectID: identity.projectID,
            threadID: identity.threadID,
            sessionID: identity.sessionID,
            taskRunID: taskRunID,
            mode: existingState?.mode ?? .auto,
            lifecycle: lifecycle,
            revision: (existingState?.revision ?? 0) + 1,
            title: normalized(items.first?.title ?? "任务", limit: 48, fallback: "任务"),
            summary: normalized(args.reason, limit: 160, fallback: "更新任务状态"),
            focusItemID: focusItemID,
            items: items,
            metadata: existingState?.metadata ?? .empty,
            createdAt: existingState?.createdAt ?? now,
            updatedAt: now
        )
    }

    private func normalizeInProgress(_ items: inout [AgentTaskItem]) {
        let activeIndices = items.indices.filter { items[$0].status == .inProgress }
        if !activeIndices.isEmpty {
            for index in activeIndices.dropFirst() {
                items[index].status = .pending
            }
            return
        }

        guard let firstPending = items.firstIndex(where: { $0.status == .pending }) else {
            return
        }
        items[firstPending].status = .inProgress
    }

    private func resolvedLifecycle(
        requested: AgentTaskLifecycle?,
        items: [AgentTaskItem],
        existing: AgentTaskLifecycle?
    ) -> AgentTaskLifecycle {
        if let requested {
            return requested
        }
        if items.allSatisfy({ $0.status.isTerminal }) {
            return .completed
        }
        if items.contains(where: { $0.status == .blocked }) {
            return .blocked
        }
        if existing == .waitingForUser {
            return .waitingForUser
        }
        return .active
    }

    private func evidenceReferences(
        toolUseIDs: [String]?,
        previous: [AgentTaskEvidenceRef]
    ) -> [AgentTaskEvidenceRef] {
        guard let toolUseIDs else { return previous }
        return toolUseIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(6)
            .map { toolUseID in
                AgentTaskEvidenceRef(
                    kind: .toolResult,
                    toolUseID: toolUseID,
                    fileDeltaID: nil,
                    eventLogID: nil,
                    title: toolUseID
                )
            }
    }

    private func equivalent(lhs: AgentTaskState, rhs: AgentTaskState) -> Bool {
        lhs.lifecycle == rhs.lifecycle &&
            lhs.focusItemID == rhs.focusItemID &&
            lhs.items.map(\.id) == rhs.items.map(\.id) &&
            lhs.items.map(\.title) == rhs.items.map(\.title) &&
            lhs.items.map(\.status) == rhs.items.map(\.status) &&
            lhs.items.map(\.displaySummary) == rhs.items.map(\.displaySummary)
    }

    private func nextGeneratedIDIndex(from items: [AgentTaskItem]) -> Int {
        let values = items.compactMap { item -> Int? in
            guard item.id.first == "t" else { return nil }
            return Int(item.id.dropFirst())
        }
        return (values.max() ?? 0) + 1
    }

    private func nextID(usedIDs: Set<String>, nextIDIndex: inout Int) -> String {
        while usedIDs.contains("t\(nextIDIndex)") {
            nextIDIndex += 1
        }
        let value = "t\(nextIDIndex)"
        nextIDIndex += 1
        return value
    }

    private func uniqueID(
        _ candidate: String,
        usedIDs: inout Set<String>,
        nextIDIndex: inout Int
    ) -> String {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCandidate = trimmed.isEmpty
            ? nextID(usedIDs: usedIDs, nextIDIndex: &nextIDIndex)
            : normalized(trimmed, limit: 32)
        if !usedIDs.contains(normalizedCandidate) {
            usedIDs.insert(normalizedCandidate)
            return normalizedCandidate
        }
        let generated = nextID(usedIDs: usedIDs, nextIDIndex: &nextIDIndex)
        usedIDs.insert(generated)
        return generated
    }

    private func normalizedList(_ values: [String], limit: Int, itemLimit: Int) -> [String] {
        Array(
            values
                .map { normalized($0, limit: itemLimit) }
                .filter { !$0.isEmpty }
                .prefix(limit)
        )
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ value: String, limit: Int, fallback: String = "") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : trimmed
        guard resolved.count > limit else { return resolved }
        return String(resolved.prefix(limit))
    }

    private func successPayload(state: AgentTaskState, reason: String, noOp: Bool) -> String {
        let payload: [String: Any] = [
            "status": "updated",
            "task_run_id": state.taskRunID.uuidString,
            "revision": state.revision,
            "lifecycle": state.lifecycle.rawValue,
            "completed": state.completedCount,
            "total": state.totalCount,
            "no_op": noOp,
            "reason": normalized(reason, limit: 120)
        ]
        return jsonString(payload)
    }

    private func errorPayload(_ message: String) -> String {
        jsonString([
            "status": "error",
            "message": message
        ])
    }

    private func limitedResult(
        identity: AgentTaskStateIdentity,
        snapshot: AgentTaskStateSnapshot?,
        reason: String
    ) -> AgentTaskUpdateResult {
        let resolvedSnapshot = snapshot ?? AgentTaskStateSnapshot(
            projectID: identity.projectID,
            threadID: identity.threadID,
            sessionID: identity.sessionID,
            currentRunID: nil,
            currentState: nil,
            recentRuns: [],
            unavailableReason: nil,
            updatedAt: .now
        )
        return AgentTaskUpdateResult(
            state: resolvedSnapshot.currentState,
            snapshot: resolvedSnapshot,
            payload: errorPayload(reason),
            summary: reason,
            isError: true,
            isNoOp: false
        )
    }

    private func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"status":"error","message":"无法序列化任务状态结果"}"#
        }
        return string
    }
}
