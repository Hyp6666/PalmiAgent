import Foundation

/// Pure reducer for atomic single-task mutations.
struct AgentTaskStateReducer {
    static let maximumTaskCount = 12

    func reduce(
        args: UpdateTaskArgs,
        identity: AgentTaskStateIdentity,
        existingState: AgentTaskState?,
        now: Date = .now
    ) throws -> AgentTaskState {
        let startsNewRun = existingState == nil || existingState?.lifecycle.isActiveLike == false
        var items = startsNewRun ? [] : (existingState?.items ?? [])

        let changedTaskID: String
        switch args.operation {
        case .create:
            guard items.count < Self.maximumTaskCount else {
                throw AppError.invalidState("任务最多只能有 \(Self.maximumTaskCount) 项。")
            }
            let title = normalized(args.title ?? "", limit: 64)
            guard !title.isEmpty else {
                throw AppError.invalidState("update_task(operation=create) 必须提供 title。")
            }
            let requestedID = normalizedOptional(args.taskID)
            let taskID = requestedID ?? nextID(from: items)
            guard !items.contains(where: { $0.id == taskID }) else {
                throw AppError.invalidState("task_id 已存在：\(taskID)")
            }
            let status = args.status ?? .pending
            items.append(
                AgentTaskItem(
                    id: taskID,
                    title: title,
                    status: status,
                    displaySummary: normalized(args.displaySummary ?? title, limit: 200, fallback: title),
                    hiddenDetail: normalizedOptional(args.hiddenDetail),
                    detailPath: nil,
                    acceptanceCriteria: normalizedList(args.acceptanceCriteria ?? [], limit: 6, itemLimit: 200),
                    evidenceReferences: evidenceReferences(toolUseIDs: args.evidenceToolUseIDs, previous: []),
                    createdAt: now,
                    updatedAt: now
                )
            )
            changedTaskID = taskID

        case .update:
            guard !startsNewRun, let existingState else {
                throw AppError.invalidState("当前没有可更新的活动 task 列表；请先使用 operation=create。")
            }
            _ = existingState
            guard let taskID = normalizedOptional(args.taskID) else {
                throw AppError.invalidState("update_task(operation=update) 必须提供 task_id。")
            }
            guard let index = items.firstIndex(where: { $0.id == taskID }) else {
                throw AppError.invalidState("没有找到 task_id：\(taskID)")
            }
            let previous = items[index]
            if previous.status.isTerminal,
               let requestedStatus = args.status,
               !requestedStatus.isTerminal {
                throw AppError.invalidState("已终态 task 不能回退到非终态：\(taskID)")
            }
            let title = args.title.map { normalized($0, limit: 64, fallback: previous.title) } ?? previous.title
            items[index] = AgentTaskItem(
                id: previous.id,
                title: title,
                status: args.status ?? previous.status,
                displaySummary: args.displaySummary.map {
                    normalized($0, limit: 200, fallback: previous.displaySummary)
                } ?? previous.displaySummary,
                hiddenDetail: args.hiddenDetail.map(normalizedOptional) ?? previous.hiddenDetail,
                detailPath: previous.detailPath,
                acceptanceCriteria: args.acceptanceCriteria.map {
                    normalizedList($0, limit: 6, itemLimit: 200)
                } ?? previous.acceptanceCriteria,
                evidenceReferences: evidenceReferences(
                    toolUseIDs: args.evidenceToolUseIDs,
                    previous: previous.evidenceReferences
                ),
                createdAt: previous.createdAt,
                updatedAt: now
            )
            changedTaskID = taskID
        }

        normalizeInProgress(&items, preferredTaskID: changedTaskID)
        let lifecycle = derivedLifecycle(from: items)
        let focusItemID = items.first(where: { $0.status == .inProgress })?.id
            ?? items.first(where: { $0.status == .waitingForUser })?.id
            ?? items.first(where: { $0.status == .blocked })?.id
            ?? items.first(where: { $0.status == .pending })?.id
        let changedItem = items.first(where: { $0.id == changedTaskID })!

        return AgentTaskState(
            schemaVersion: 3,
            id: startsNewRun ? UUID() : (existingState?.id ?? UUID()),
            projectID: identity.projectID,
            threadID: identity.threadID,
            sessionID: identity.sessionID,
            taskRunID: startsNewRun ? UUID() : (existingState?.taskRunID ?? UUID()),
            mode: startsNewRun ? .auto : (existingState?.mode ?? .auto),
            lifecycle: lifecycle,
            revision: (existingState?.revision ?? 0) + 1,
            title: normalized(items.first?.title ?? "任务", limit: 64, fallback: "任务"),
            summary: "\(args.operation.rawValue)：\(changedItem.title)",
            focusItemID: focusItemID,
            items: items,
            metadata: startsNewRun ? .empty : (existingState?.metadata ?? .empty),
            createdAt: startsNewRun ? now : (existingState?.createdAt ?? now),
            updatedAt: now
        )
    }

    private func normalizeInProgress(_ items: inout [AgentTaskItem], preferredTaskID: String) {
        if let preferredIndex = items.firstIndex(where: {
            $0.id == preferredTaskID && $0.status == .inProgress
        }) {
            for index in items.indices where index != preferredIndex && items[index].status == .inProgress {
                items[index].status = .pending
            }
            return
        }
        let activeIndices = items.indices.filter { items[$0].status == .inProgress }
        if let first = activeIndices.first {
            for index in activeIndices where index != first {
                items[index].status = .pending
            }
            return
        }
        if let firstPending = items.firstIndex(where: { $0.status == .pending }) {
            items[firstPending].status = .inProgress
        }
    }

    private func derivedLifecycle(from items: [AgentTaskItem]) -> AgentTaskLifecycle {
        if items.allSatisfy({ $0.status.isTerminal }) {
            return .completed
        }
        if items.contains(where: { $0.status == .inProgress || $0.status == .pending }) {
            return .active
        }
        if items.contains(where: { $0.status == .waitingForUser }) {
            return .waitingForUser
        }
        return .blocked
    }

    private func evidenceReferences(
        toolUseIDs: [String]?,
        previous: [AgentTaskEvidenceRef]
    ) -> [AgentTaskEvidenceRef] {
        guard let toolUseIDs else { return previous }
        return toolUseIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(8)
            .map {
                AgentTaskEvidenceRef(
                    kind: .toolResult,
                    toolUseID: $0,
                    fileDeltaID: nil,
                    eventLogID: nil,
                    title: $0
                )
            }
    }

    private func nextID(from items: [AgentTaskItem]) -> String {
        let next = (items.compactMap { item -> Int? in
            guard item.id.first == "t" else { return nil }
            return Int(item.id.dropFirst())
        }.max() ?? 0) + 1
        return "t\(next)"
    }

    private func normalizedList(_ values: [String], limit: Int, itemLimit: Int) -> [String] {
        Array(values.map { normalized($0, limit: itemLimit) }.filter { !$0.isEmpty }.prefix(limit))
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ value: String, limit: Int, fallback: String = "") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : trimmed
        return String(resolved.prefix(limit))
    }
}
