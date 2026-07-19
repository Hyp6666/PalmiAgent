import Foundation

@MainActor
final class TaskStateRuntime {
    private let fileStore: TaskStateFileStore
    private let decoder = JSONDecoder()
    private let reducer = AgentTaskStateReducer()

    init(fileStore: TaskStateFileStore) {
        self.fileStore = fileStore
    }

    func beginTurn() {}

    func recordNonTaskProgress() {}

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
        do {
            let args = try decoder.decode(UpdateTaskArgs.self, from: Data(input.utf8))
            let latestSnapshot = try fileStore.loadSnapshot(identity: identity, fallback: snapshot)
            let oldState = latestSnapshot.currentState
            let state = try reducer.reduce(
                args: args,
                identity: identity,
                existingState: oldState,
                now: .now
            )
            guard !equivalent(lhs: oldState, rhs: state) else {
                throw AppError.invalidState("本次 update_task 没有产生任何变化。")
            }
            let expectedRevision = oldState?.lifecycle.isActiveLike == true
                ? oldState?.revision
                : nil
            let changedTaskID = normalizedTaskID(args.taskID)
                ?? changedTaskID(from: oldState, to: state)
                ?? state.focusItemID
                ?? state.items.last?.id
                ?? ""
            let changedItem = state.items.first(where: { $0.id == changedTaskID })
            let savedSnapshot = try fileStore.save(
                state: state,
                reason: "\(args.operation.rawValue)：\(changedItem?.title ?? changedTaskID)",
                expectedRevision: expectedRevision
            )
            return AgentTaskUpdateResult(
                state: state,
                snapshot: savedSnapshot,
                payload: successPayload(
                    state: state,
                    operation: args.operation,
                    taskID: changedTaskID,
                    taskStatus: changedItem?.status
                ),
                summary: "\(args.operation == .create ? "创建" : "更新") · \(changedItem?.title ?? changedTaskID) · \(changedItem?.status.rawValue ?? state.lifecycle.rawValue)",
                isError: false,
                isNoOp: false
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let fallbackSnapshot = (try? fileStore.loadSnapshot(identity: identity, fallback: snapshot))
                ?? snapshot
                ?? emptySnapshot(identity: identity)
            return AgentTaskUpdateResult(
                state: fallbackSnapshot.currentState,
                snapshot: fallbackSnapshot,
                payload: errorPayload(message, snapshot: fallbackSnapshot),
                summary: message,
                isError: true,
                isNoOp: false
            )
        }
    }

    private func equivalent(lhs: AgentTaskState?, rhs: AgentTaskState) -> Bool {
        guard let lhs else { return false }
        return lhs.lifecycle == rhs.lifecycle &&
            lhs.focusItemID == rhs.focusItemID &&
            lhs.items.map(\.id) == rhs.items.map(\.id) &&
            lhs.items.map(\.title) == rhs.items.map(\.title) &&
            lhs.items.map(\.status) == rhs.items.map(\.status) &&
            lhs.items.map(\.displaySummary) == rhs.items.map(\.displaySummary) &&
            lhs.items.map(\.hiddenDetail) == rhs.items.map(\.hiddenDetail) &&
            lhs.items.map(\.acceptanceCriteria) == rhs.items.map(\.acceptanceCriteria) &&
            evidenceSignatures(lhs.items) == evidenceSignatures(rhs.items)
    }

    private func evidenceSignatures(_ items: [AgentTaskItem]) -> [[String]] {
        items.map { item in
            item.evidenceReferences.map { reference in
                [
                    reference.kind.rawValue,
                    reference.toolUseID ?? "",
                    reference.fileDeltaID?.uuidString ?? "",
                    reference.eventLogID?.uuidString ?? "",
                    reference.title
                ].joined(separator: "|")
            }
        }
    }

    private func changedTaskID(from oldState: AgentTaskState?, to state: AgentTaskState) -> String? {
        let oldItems = Dictionary(uniqueKeysWithValues: (oldState?.items ?? []).map { ($0.id, $0) })
        return state.items.first { item in
            guard let old = oldItems[item.id] else { return true }
            return old.title != item.title ||
                old.status != item.status ||
                old.displaySummary != item.displaySummary ||
                old.hiddenDetail != item.hiddenDetail ||
                old.acceptanceCriteria != item.acceptanceCriteria
        }?.id
    }

    private func normalizedTaskID(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func successPayload(
        state: AgentTaskState,
        operation: UpdateTaskOperation,
        taskID: String,
        taskStatus: AgentTaskItemStatus?
    ) -> String {
        jsonString([
            "status": operation == .create ? "created" : "updated",
            "operation": operation.rawValue,
            "task_id": taskID,
            "task_status": taskStatus?.rawValue ?? "unknown",
            "task_run_id": state.taskRunID.uuidString,
            "revision": state.revision,
            "lifecycle": state.lifecycle.rawValue,
            "completed": state.completedCount,
            "total": state.totalCount
        ])
    }

    private func errorPayload(_ message: String, snapshot: AgentTaskStateSnapshot) -> String {
        var payload: [String: Any] = [
            "status": "error",
            "message": message
        ]
        if let state = snapshot.currentState {
            payload["current_revision"] = state.revision
            payload["task_run_id"] = state.taskRunID.uuidString
        }
        return jsonString(payload)
    }

    private func emptySnapshot(identity: AgentTaskStateIdentity) -> AgentTaskStateSnapshot {
        AgentTaskStateSnapshot(
            projectID: identity.projectID,
            threadID: identity.threadID,
            sessionID: identity.sessionID,
            currentRunID: nil,
            currentState: nil,
            recentRuns: [],
            unavailableReason: nil,
            updatedAt: .now
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
