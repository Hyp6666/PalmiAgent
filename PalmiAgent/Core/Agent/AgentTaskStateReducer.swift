import Foundation

/// Pure reducer for atomic whole-list task updates.
struct AgentTaskStateReducer {
    static let maximumTaskCount = 12

    func reduce(
        args: UpdateTaskStateArgs,
        identity: AgentTaskStateIdentity,
        existingState: AgentTaskState?,
        now: Date = .now
    ) throws -> AgentTaskState {
        guard !args.tasks.isEmpty else {
            throw AppError.invalidState("任务列表不能为空。")
        }
        guard args.tasks.count <= Self.maximumTaskCount else {
            throw AppError.invalidState("任务最多只能有 \(Self.maximumTaskCount) 项，请合并后重试。")
        }
        if existingState?.lifecycle.isActiveLike == true {
            guard let expectedRevision = args.expectedRevision else {
                throw AppError.invalidState("更新已有任务列表必须携带 expectedRevision。")
            }
            guard expectedRevision == existingState?.revision else {
                throw AppError.invalidState(
                    "任务版本已变化（当前 \(existingState?.revision ?? 0)，请求 \(expectedRevision)），请读取最新列表后重试。"
                )
            }
        } else if let expectedRevision = args.expectedRevision,
                  expectedRevision != (existingState?.revision ?? 0) {
            throw AppError.invalidState(
                "任务版本已变化（当前 \(existingState?.revision ?? 0)，请求 \(expectedRevision)），请读取最新列表后重试。"
            )
        }

        let shouldCreateNewRun = existingState == nil || existingState?.lifecycle.isActiveLike == false
        let oldItems = shouldCreateNewRun ? [] : (existingState?.items ?? [])
        let oldItemsByID = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0) })
        var usedIDs: Set<String> = []
        var nextIDIndex = nextGeneratedIDIndex(from: oldItems)
        var items: [AgentTaskItem] = []

        for (index, input) in args.tasks.enumerated() {
            let candidateID = normalizedOptional(input.id)
                ?? (index < oldItems.count ? oldItems[index].id : nil)
                ?? nextID(usedIDs: usedIDs, nextIDIndex: &nextIDIndex)
            let id = uniqueID(candidateID, usedIDs: &usedIDs, nextIDIndex: &nextIDIndex)
            let previous = oldItemsByID[id]
            let status = if previous?.status.isTerminal == true && !input.status.isTerminal {
                previous!.status
            } else {
                input.status
            }
            items.append(
                AgentTaskItem(
                    id: id,
                    title: normalized(input.title, limit: 64, fallback: previous?.title ?? "任务"),
                    status: status,
                    displaySummary: normalized(
                        input.displaySummary ?? previous?.displaySummary ?? input.title,
                        limit: 200,
                        fallback: previous?.displaySummary ?? input.title
                    ),
                    hiddenDetail: normalizedOptional(input.hiddenDetail) ?? previous?.hiddenDetail,
                    detailPath: previous?.detailPath,
                    acceptanceCriteria: normalizedList(
                        input.acceptanceCriteria ?? previous?.acceptanceCriteria ?? [],
                        limit: 6,
                        itemLimit: 200
                    ),
                    evidenceReferences: evidenceReferences(
                        toolUseIDs: input.evidenceToolUseIDs,
                        previous: previous?.evidenceReferences ?? []
                    ),
                    createdAt: previous?.createdAt ?? now,
                    updatedAt: now
                )
            )
        }

        for oldItem in oldItems where oldItem.status.isTerminal && !usedIDs.contains(oldItem.id) {
            guard items.count < Self.maximumTaskCount else { break }
            items.append(oldItem)
            usedIDs.insert(oldItem.id)
        }

        let lifecycle = normalizeLifecycle(args.lifecycle, items: &items, existing: existingState?.lifecycle)
        normalizeInProgress(&items, lifecycle: lifecycle)

        let requestedFocus = normalizedOptional(args.focusItemID)
        let focusItemID = requestedFocus.flatMap { focus in
            items.first(where: { $0.id == focus && !$0.status.isTerminal })?.id
        } ?? items.first(where: { $0.status == .inProgress })?.id
            ?? items.first(where: { !$0.status.isTerminal })?.id

        return AgentTaskState(
            schemaVersion: 2,
            id: shouldCreateNewRun ? UUID() : (existingState?.id ?? UUID()),
            projectID: identity.projectID,
            threadID: identity.threadID,
            sessionID: identity.sessionID,
            taskRunID: shouldCreateNewRun ? UUID() : (existingState?.taskRunID ?? UUID()),
            mode: shouldCreateNewRun ? .auto : (existingState?.mode ?? .auto),
            lifecycle: lifecycle,
            revision: (existingState?.revision ?? 0) + 1,
            title: normalized(items.first?.title ?? "任务", limit: 64, fallback: "任务"),
            summary: normalized(args.reason, limit: 200, fallback: "更新任务状态"),
            focusItemID: focusItemID,
            items: items,
            metadata: shouldCreateNewRun ? .empty : (existingState?.metadata ?? .empty),
            createdAt: shouldCreateNewRun ? now : (existingState?.createdAt ?? now),
            updatedAt: now
        )
    }

    private func normalizeLifecycle(
        _ requested: AgentTaskLifecycle?,
        items: inout [AgentTaskItem],
        existing: AgentTaskLifecycle?
    ) -> AgentTaskLifecycle {
        if requested == .completed {
            for index in items.indices where !items[index].status.isTerminal {
                items[index].status = .completed
            }
            return .completed
        }
        if requested == .abandoned {
            for index in items.indices where !items[index].status.isTerminal {
                items[index].status = .canceled
            }
            return .abandoned
        }
        if items.allSatisfy({ $0.status.isTerminal }) {
            return .completed
        }
        if let requested {
            return requested
        }
        if items.contains(where: { $0.status == .blocked }) {
            return .blocked
        }
        return existing == .waitingForUser ? .waitingForUser : .active
    }

    private func normalizeInProgress(
        _ items: inout [AgentTaskItem],
        lifecycle: AgentTaskLifecycle
    ) {
        guard lifecycle == .active else {
            for index in items.indices where items[index].status == .inProgress {
                items[index].status = lifecycle == .blocked ? .blocked : .pending
            }
            return
        }
        let activeIndices = items.indices.filter { items[$0].status == .inProgress }
        if let first = activeIndices.first {
            for index in activeIndices where index != first {
                items[index].status = .pending
            }
        } else if let firstPending = items.firstIndex(where: { $0.status == .pending }) {
            items[firstPending].status = .inProgress
        }
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

    private func nextGeneratedIDIndex(from items: [AgentTaskItem]) -> Int {
        (items.compactMap { item -> Int? in
            guard item.id.first == "t" else { return nil }
            return Int(item.id.dropFirst())
        }.max() ?? 0) + 1
    }

    private func nextID(usedIDs: Set<String>, nextIDIndex: inout Int) -> String {
        while usedIDs.contains("t\(nextIDIndex)") { nextIDIndex += 1 }
        defer { nextIDIndex += 1 }
        return "t\(nextIDIndex)"
    }

    private func uniqueID(
        _ candidate: String,
        usedIDs: inout Set<String>,
        nextIDIndex: inout Int
    ) -> String {
        let trimmed = normalized(candidate, limit: 40)
        let value = trimmed.isEmpty ? nextID(usedIDs: usedIDs, nextIDIndex: &nextIDIndex) : trimmed
        if usedIDs.insert(value).inserted { return value }
        let generated = nextID(usedIDs: usedIDs, nextIDIndex: &nextIDIndex)
        usedIDs.insert(generated)
        return generated
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
