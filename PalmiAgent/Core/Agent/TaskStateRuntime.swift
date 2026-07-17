import Foundation

@MainActor
final class TaskStateRuntime {
    private let fileStore: TaskStateFileStore
    private let decoder = JSONDecoder()
    private let reducer = AgentTaskStateReducer()

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
            let state = try reducer.reduce(
                args: args,
                identity: identity,
                existingState: oldState,
                now: .now
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
            let expectedPersistedRevision = oldState?.lifecycle.isActiveLike == true
                ? args.expectedRevision
                : nil
            let savedSnapshot = try fileStore.save(
                state: state,
                reason: normalized(args.reason, limit: 120),
                expectedRevision: expectedPersistedRevision
            )
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
            // A rejected decode/CAS did not mutate state. Keep retry possible
            // after projecting the latest disk snapshot back to the model.
            lastMutationWasTaskUpdate = false
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let fallbackSnapshot = (try? fileStore.loadSnapshot(identity: identity, fallback: snapshot))
                ?? snapshot
                ?? AgentTaskStateSnapshot(
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
                payload: errorPayload(message, snapshot: fallbackSnapshot),
                summary: message,
                isError: true,
                isNoOp: false
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

    private func errorPayload(
        _ message: String,
        snapshot: AgentTaskStateSnapshot
    ) -> String {
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
            payload: errorPayload(reason, snapshot: resolvedSnapshot),
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
