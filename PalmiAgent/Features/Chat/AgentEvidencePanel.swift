import SwiftUI

struct AgentEvidencePanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSections: Set<AgentEvidenceSectionKind> = [.tasks]

    let snapshot: AgentEvidenceSnapshot

    var body: some View {
        NavigationStack {
            List {
                if !snapshot.hasContent {
                    Text(PalmiL10n.tr("evidence.empty"))
                        .foregroundStyle(.secondary)
                }

                if let taskState = snapshot.taskState {
                    evidenceSection(.tasks, count: taskState.taskDisplayCount) {
                        AgentTaskOverview(snapshot: taskState)
                    }
                }

                evidenceSection(.tools, count: snapshot.toolAudits.count) {
                    ForEach(snapshot.toolAudits) { record in
                        ToolAuditRow(record: record)
                    }
                }

                evidenceSection(.files, count: snapshot.fileDeltas.count) {
                    ForEach(snapshot.fileDeltas) { delta in
                        FileDeltaRow(delta: delta)
                    }
                }

                evidenceSection(.references, count: snapshot.evidenceReferences.count) {
                    ForEach(Array(snapshot.evidenceReferences.enumerated()), id: \.offset) { _, reference in
                        EvidenceReferenceRow(reference: reference)
                    }
                }

                evidenceSection(.approvals, count: snapshot.confirmations.count) {
                    ForEach(snapshot.confirmations) { record in
                        ConfirmationRow(record: record)
                    }
                }

                evidenceSection(.events, count: snapshot.eventLogEntries.count) {
                    ForEach(snapshot.eventLogEntries) { entry in
                        EventLogRow(entry: entry)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(PalmiL10n.tr("evidence.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PalmiL10n.tr("common.close"))
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(44)
    }

    @ViewBuilder
    private func evidenceSection<Content: View>(
        _ kind: AgentEvidenceSectionKind,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if count > 0 {
            Section {
                Button {
                    toggleSection(kind)
                } label: {
                    AgentEvidenceSectionHeader(
                        kind: kind,
                        count: count,
                        isExpanded: expandedSections.contains(kind)
                    )
                    .padding(.vertical, 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 32, bottom: 0, trailing: 32))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityLabel(PalmiL10n.tr("evidence.section.accessibility", kind.title, count))

                if expandedSections.contains(kind) {
                    content()
                }
            }
        }
    }

    private func toggleSection(_ kind: AgentEvidenceSectionKind) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedSections.contains(kind) {
                expandedSections.remove(kind)
            } else {
                expandedSections.insert(kind)
            }
        }
    }
}

private enum AgentEvidenceSectionKind: Hashable {
    case tasks
    case tools
    case files
    case references
    case approvals
    case events

    var title: String {
        switch self {
        case .tasks:
            PalmiL10n.tr("evidence.section.tasks")
        case .tools:
            PalmiL10n.tr("evidence.section.tools")
        case .files:
            PalmiL10n.tr("evidence.section.files")
        case .references:
            PalmiL10n.tr("evidence.section.references")
        case .approvals:
            PalmiL10n.tr("evidence.section.approvals")
        case .events:
            PalmiL10n.tr("evidence.section.events")
        }
    }

    var systemImage: String {
        switch self {
        case .tasks:
            "checklist"
        case .tools:
            "wrench.and.screwdriver"
        case .files:
            "doc.text"
        case .references:
            "quote.bubble"
        case .approvals:
            "checkmark.shield"
        case .events:
            "clock"
        }
    }
}

private struct AgentEvidenceSectionHeader: View {
    let kind: AgentEvidenceSectionKind
    let count: Int
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.08), in: Circle())

            Text(kind.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Text(count.formatted())
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary.opacity(0.72))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary.opacity(0.55))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentTaskOverview: View {
    let snapshot: AgentTaskStateSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reason = snapshot.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            if let state = snapshot.currentState {
                AgentTaskCurrentRunView(state: state)
            }

            if !historyRuns.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(PalmiL10n.tr("evidence.task.history"))
                            .font(.subheadline.weight(.semibold))
                        Text(historyRuns.count.formatted())
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(historyRuns.prefix(3)) { run in
                        AgentTaskHistoryRunRow(run: run)
                    }
                }
                .padding(.top, stateTopPadding)
            }
        }
        .padding(.vertical, 4)
    }

    private var historyRuns: [AgentTaskRunSummary] {
        guard let currentRunID = snapshot.currentRunID else {
            return snapshot.recentRuns
        }
        return snapshot.recentRuns.filter { $0.taskRunID != currentRunID }
    }

    private var stateTopPadding: CGFloat {
        snapshot.currentState == nil ? 0 : 4
    }
}

private struct AgentTaskCurrentRunView: View {
    let state: AgentTaskState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(state.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                Text([state.completedCount.formatted(), state.totalCount.formatted()].joined(separator: "/"))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            ForEach(state.items) { item in
                AgentTaskItemRow(item: item, isFocused: item.id == state.focusItemID)
            }

            Text(PalmiL10n.tr("evidence.updatedAt", state.updatedAt.formatted(date: .omitted, time: .shortened)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AgentTaskItemRow: View {
    let item: AgentTaskItem
    let isFocused: Bool
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.status.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item.status.tint)
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.subheadline.weight(isFocused ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if isFocused {
                                Text(PalmiL10n.tr("evidence.task.current"))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.primary.opacity(0.72))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }

                        Text(item.displaySummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? 3 : 1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }

                if isExpanded {
                    AgentTaskItemDetail(item: item)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AgentTaskItemDetail: View {
    let item: AgentTaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hiddenDetail = item.hiddenDetail,
               !hiddenDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(hiddenDetail)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            if !item.acceptanceCriteria.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(PalmiL10n.tr("evidence.task.acceptance"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(item.acceptanceCriteria.enumerated()), id: \.offset) { _, criterion in
                        Text(criterion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !item.evidenceReferences.isEmpty {
                Text(PalmiL10n.tr(
                    "evidence.task.references",
                    item.evidenceReferences.map(\.title).joined(separator: PalmiL10n.tr("common.listSeparator"))
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 28)
    }
}

private struct AgentTaskHistoryRunRow: View {
    let run: AgentTaskRunSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.lifecycle.historySystemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(run.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text([run.completedCount.formatted(), run.totalCount.formatted()].joined(separator: "/"))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ToolAuditRow: View {
    let record: ToolAuditRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(localizedToolTitle)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(record.riskLevel.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(record.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Text(record.argumentsJSON)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    private var localizedToolTitle: String {
        AgentExternalToolFacadeCatalog.localizedTitle(for: record.toolName) ?? record.toolName
    }
}

private struct FileDeltaRow: View {
    let delta: FileDelta

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(delta.path)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(delta.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(delta.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
            if let byteSummary {
                Text(byteSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    private var byteSummary: String? {
        switch (delta.beforeByteCount, delta.afterByteCount) {
        case let (.some(before), .some(after)):
            "\(before) B -> \(after) B"
        case let (.some(before), .none):
            "\(before) B"
        case let (.none, .some(after)):
            "\(after) B"
        case (.none, .none):
            nil
        }
    }
}

private struct EvidenceReferenceRow: View {
    let reference: EvidenceReference

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(reference.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(reference.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(reference.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(6)
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }
}

private struct ConfirmationRow: View {
    let record: UserConfirmationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(localizedToolTitle)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(record.approved ? PalmiL10n.tr("evidence.approval.approved") : PalmiL10n.tr("evidence.approval.rejected"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(record.approved ? .green : .red)
            }
            Text([record.riskLevel.title, record.policy.localizedTitle].joined(separator: " / "))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(record.argumentsJSON)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }

    private var localizedToolTitle: String {
        AgentExternalToolFacadeCatalog.localizedTitle(for: record.toolName) ?? record.toolName
    }
}

private struct EventLogRow: View {
    let entry: AgentEventLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.kind.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(entry.createdAt, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
            if let payloadJSON = entry.payloadJSON, !payloadJSON.isEmpty {
                Text(payloadJSON)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }
}

private extension ToolConfirmationPolicy {
    var title: String {
        switch self {
        case .allow:
            PalmiL10n.tr("tool.confirmation.allow")
        case .firstUse:
            PalmiL10n.tr("tool.confirmation.firstUse")
        case .always:
            PalmiL10n.tr("tool.confirmation.always")
        }
    }
}

private extension FileDeltaKind {
    var title: String {
        switch self {
        case .created:
            PalmiL10n.tr("evidence.fileDelta.created")
        case .modified:
            PalmiL10n.tr("evidence.fileDelta.modified")
        case .deleted:
            PalmiL10n.tr("evidence.fileDelta.deleted")
        case .directoryCreated:
            PalmiL10n.tr("evidence.fileDelta.directoryCreated")
        case .exported:
            PalmiL10n.tr("evidence.fileDelta.exported")
        case .possibleMutation:
            PalmiL10n.tr("evidence.fileDelta.possibleMutation")
        }
    }
}

private extension EvidenceReferenceKind {
    var title: String {
        switch self {
        case .searchSelection:
            PalmiL10n.tr("evidence.reference.searchSelection")
        case .sourceDigest:
            PalmiL10n.tr("evidence.reference.sourceDigest")
        case .researchSynthesis:
            PalmiL10n.tr("evidence.reference.researchSynthesis")
        case .toolResult:
            PalmiL10n.tr("evidence.reference.toolResult")
        case .fileDelta:
            PalmiL10n.tr("evidence.reference.fileDelta")
        }
    }
}

private extension AgentEventLogKind {
    var title: String {
        switch self {
        case .turnStarted:
            PalmiL10n.tr("evidence.event.turnStarted")
        case .modelRequest:
            PalmiL10n.tr("evidence.event.modelRequest")
        case .modelResponse:
            PalmiL10n.tr("evidence.event.modelResponse")
        case .modelFailure:
            PalmiL10n.tr("evidence.event.modelFailure")
        case .toolApprovalRequested:
            PalmiL10n.tr("evidence.event.toolApprovalRequested")
        case .toolApprovalResolved:
            PalmiL10n.tr("evidence.event.toolApprovalResolved")
        case .toolStarted:
            PalmiL10n.tr("evidence.event.toolStarted")
        case .toolFinished:
            PalmiL10n.tr("evidence.event.toolFinished")
        case .contextCompactionStarted:
            PalmiL10n.tr("evidence.event.contextCompactionStarted")
        case .contextCompactionFinished:
            PalmiL10n.tr("evidence.event.contextCompactionFinished")
        case .taskStateUpdated:
            PalmiL10n.tr("evidence.event.taskStateUpdated")
        case .budgetStop:
            PalmiL10n.tr("evidence.event.budgetStop")
        case .finalReply:
            PalmiL10n.tr("evidence.event.finalReply")
        }
    }
}

private extension AgentTaskStateSnapshot {
    var taskDisplayCount: Int {
        if let currentState {
            return max(1, currentState.totalCount)
        }
        return max(1, recentRuns.count)
    }
}

private extension AgentTaskItemStatus {
    var systemImage: String {
        switch self {
        case .pending:
            "circle"
        case .inProgress:
            "circle.dotted"
        case .completed:
            "checkmark.circle.fill"
        case .blocked:
            "exclamationmark.circle.fill"
        case .waitingForUser:
            "person.crop.circle.badge.clock"
        case .skipped:
            "forward.circle"
        case .canceled:
            "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            .secondary
        case .inProgress:
            .blue
        case .completed:
            .green
        case .blocked:
            .orange
        case .waitingForUser:
            .purple
        case .skipped:
            .secondary
        case .canceled:
            .red
        }
    }
}

private extension AgentTaskLifecycle {
    var historySystemImage: String {
        switch self {
        case .active:
            "circle.dotted"
        case .waitingForUser:
            "pause.circle"
        case .blocked:
            "exclamationmark.circle"
        case .completed:
            "checkmark.circle"
        case .abandoned:
            "xmark.circle"
        }
    }
}
