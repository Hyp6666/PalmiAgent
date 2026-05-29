import SwiftUI

struct AgentEvidencePanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSections: Set<AgentEvidenceSectionKind> = [.tasks]

    let snapshot: AgentEvidenceSnapshot

    var body: some View {
        NavigationStack {
            List {
                if !snapshot.hasContent {
                    Text("暂无过程")
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
            .navigationTitle("过程")
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
                    .accessibilityLabel("关闭")
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
                .accessibilityLabel("\(kind.title)，\(count) 项")

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
            "任务"
        case .tools:
            "工具"
        case .files:
            "文件"
        case .references:
            "依据"
        case .approvals:
            "审批"
        case .events:
            "事件"
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
                        Text("历史任务")
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

                Text("\(state.completedCount)/\(state.totalCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            ForEach(state.items) { item in
                AgentTaskItemRow(item: item, isFocused: item.id == state.focusItemID)
            }

            Text("更新于 \(state.updatedAt, style: .time)")
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
                                Text("当前")
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
                    Text("验收")
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
                Text("依据 \(item.evidenceReferences.map(\.title).joined(separator: "、"))")
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
            Text("\(run.completedCount)/\(run.totalCount)")
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
                Text(record.toolName)
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
                Text(record.toolName)
                    .font(.headline)
                Spacer(minLength: 8)
                Text(record.approved ? "已批准" : "已拒绝")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(record.approved ? .green : .red)
            }
            Text("\(record.riskLevel.title) / \(record.policy.title)")
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
            "允许"
        case .firstUse:
            "首次确认"
        case .always:
            "每次确认"
        }
    }
}

private extension FileDeltaKind {
    var title: String {
        switch self {
        case .created:
            "创建"
        case .modified:
            "修改"
        case .deleted:
            "删除"
        case .directoryCreated:
            "目录"
        case .exported:
            "导出"
        case .possibleMutation:
            "可能变更"
        }
    }
}

private extension EvidenceReferenceKind {
    var title: String {
        switch self {
        case .searchSelection:
            "搜索"
        case .sourceDigest:
            "来源"
        case .researchSynthesis:
            "综合"
        case .toolResult:
            "工具"
        case .fileDelta:
            "文件"
        }
    }
}

private extension AgentEventLogKind {
    var title: String {
        switch self {
        case .turnStarted:
            "开始"
        case .modelRequest:
            "请求"
        case .modelResponse:
            "响应"
        case .modelFailure:
            "错误"
        case .toolApprovalRequested:
            "待审批"
        case .toolApprovalResolved:
            "审批"
        case .toolStarted:
            "工具开始"
        case .toolFinished:
            "工具结束"
        case .contextCompactionStarted:
            "压缩开始"
        case .contextCompactionFinished:
            "压缩结束"
        case .taskStateUpdated:
            "任务"
        case .budgetStop:
            "停止"
        case .finalReply:
            "完成"
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
