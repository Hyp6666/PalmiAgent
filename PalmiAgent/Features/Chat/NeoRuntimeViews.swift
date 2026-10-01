import SwiftUI

private struct NeoRuntimePresentation: Identifiable {
    let id: UUID
}

struct NeoRuntimeCard: View {
    let headerID: UUID
    let header: PalmiChatSessionHeader
    let messages: [PalmiChatMessage]
    let finalMessage: PalmiChatMessage?
    let isCurrentTurn: Bool
    let streamingMessageID: UUID?
    let liveReasoningBuffer: (UUID) -> LiveReasoningBuffer?
    let onOpenRelatedThread: (UUID) -> Void

    @State private var presentation: NeoRuntimePresentation?

    private var isLive: Bool { isCurrentTurn && header.finishedAt == nil }

    private var steps: [NeoRuntimeStep] {
        NeoRuntimeTimeline.build(
            messages: messages, finalMessage: finalMessage, isLive: isLive,
            liveReasoningIDs: Set(messages.filter { liveReasoningBuffer($0.id) != nil }.map(\.id)),
            streamingMessageID: streamingMessageID, completionID: headerID
        )
    }

    private var statusText: String {
        if isLive, let latest = steps.last,
           latest.messages.first?.toolCall?.inlineMetadata?.reviewState == .needsUser {
            return PalmiL10n.tr("tool.review.needs_user")
        }
        return steps.last?.statusText ?? (isLive
            ? PalmiL10n.tr("chat.processing.waiting.1")
            : PalmiL10n.tr("neo.runtime.ended"))
    }

    var body: some View {
        Button {
            presentation = .init(id: headerID)
        } label: {
            HStack(spacing: 10) {
                NeoPalmiProcessingSprite(isLive: isLive)
                    .frame(width: 39, height: 39)
                HStack(spacing: 5) {
                    NeoRuntimeElapsedText(header: header, isLive: isLive)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("·")
                    NeoRuntimeFadingLabel(text: statusText, isRunning: isLive)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("neo-runtime-card")
        .accessibilityHint(PalmiL10n.tr("neo.runtime.open"))
        .sheet(item: $presentation) { _ in
            NeoRuntimeTimelineSheet(
                steps: steps, header: header, isLive: isLive,
                liveReasoningBuffer: liveReasoningBuffer,
                onOpenRelatedThread: onOpenRelatedThread
            )
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(30)
        }
    }
}

struct NeoRuntimeTimelineSheet: View {
    let steps: [NeoRuntimeStep]
    let header: PalmiChatSessionHeader
    let isLive: Bool
    let liveReasoningBuffer: (UUID) -> LiveReasoningBuffer?
    let onOpenRelatedThread: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedStep: NeoRuntimeStep?
    @State private var selectedDetent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    NeoRuntimeElapsedText(header: header, isLive: isLive)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if steps.isEmpty {
                        NeoRuntimeFadingLabel(
                            text: PalmiL10n.tr("chat.processing.waiting.1"), isRunning: isLive
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 20)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(steps) { step in
                                NeoRuntimeTimelineRow(step: step, isLast: step.id == steps.last?.id) {
                                    selectedStep = step
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(PalmiL10n.tr("neo.runtime.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(
                        PalmiL10n.tr(selectedDetent == .large ? "neo.runtime.collapse" : "neo.runtime.expand"),
                        systemImage: selectedDetent == .large
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    ) {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            selectedDetent = selectedDetent == .large ? .medium : .large
                        }
                    }
                    .labelStyle(.iconOnly)
                    .tint(.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityIdentifier("neo-reasoning-size-toggle")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(PalmiL10n.tr("common.close"), systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.primary)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .sheet(item: $selectedStep) { selection in
            // Resolve by stable ID on every update so an open detail stays live.
            NeoRuntimeStepDetailSheet(
                step: steps.first(where: { $0.id == selection.id }) ?? selection,
                liveReasoningBuffer: liveReasoningBuffer
            ) { threadID in
                selectedStep = nil
                dismiss()
                onOpenRelatedThread(threadID)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(30)
        }
    }
}

private struct NeoRuntimeTimelineRow: View {
    let step: NeoRuntimeStep
    let isLast: Bool
    let onSelect: () -> Void

    @ViewBuilder
    var body: some View {
        if step.kind == .explanation {
            rowContent
                .accessibilityLabel(step.messages.first?.content ?? "")
                .accessibilityIdentifier("neo-step-\(step.id.uuidString)")
        } else {
            Button(action: onSelect) { rowContent }
                .buttonStyle(.plain)
                .accessibilityLabel(step.statusText)
                .accessibilityHint(PalmiL10n.tr("neo.runtime.detail"))
                .accessibilityIdentifier("neo-step-\(step.id.uuidString)")
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if step.kind == .explanation {
                Text(step.messages.first?.content ?? "")
                    .font(.body)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                NeoRuntimeFadingLabel(text: step.statusText, isRunning: step.state == .running)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if step.kind != .explanation {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 48)
        .padding(.vertical, 14)
        .frame(minHeight: 48, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            NeoRuntimeNode(step: step)
                .padding(.leading, 2)
                .padding(.top, 8)
                .accessibilityHidden(true)
        }
        .background {
            if !isLast {
                GeometryReader { geometry in
                    Path { path in
                        path.move(to: CGPoint(x: 16, y: 40))
                        path.addLine(to: CGPoint(x: 16, y: geometry.size.height + 4))
                    }
                    .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

private struct NeoRuntimeNode: View {
    let step: NeoRuntimeStep

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(
                    lineWidth: 1, lineCap: .round, dash: step.state == .running ? [2, 3] : []
                ))
            Image(systemName: step.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 28, height: 28)
    }
}

private struct NeoRuntimeFadingLabel: View {
    let text: String
    let isRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isRunning && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    label.foregroundStyle(activityGradient(at: context.date))
                }
            } else {
                label
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: text)
    }

    private var label: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .id(text)
            .transition(.opacity)
    }

    private func activityGradient(at date: Date) -> LinearGradient {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
        let colors = (0...12).map { index in
            let wave = (sin((Double(index) / 12.0 - phase) * .pi * 2) + 1) / 2
            return Color.primary.opacity(0.46 + 0.54 * wave)
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

private struct NeoRuntimeElapsedText: View {
    let header: PalmiChatSessionHeader
    let isLive: Bool

    var body: some View {
        Group {
            if isLive {
                TimelineView(.periodic(from: header.startedAt, by: 1)) { context in
                    Text(elapsed(to: context.date))
                }
            } else {
                Text(elapsed(to: header.finishedAt ?? header.startedAt))
            }
        }
        .monospacedDigit()
    }

    private func elapsed(to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(header.startedAt)))
        if seconds < 60 { return PalmiL10n.tr("neo.runtime.elapsed.seconds", seconds) }
        return PalmiL10n.tr("neo.runtime.elapsed.minutesSeconds", seconds / 60, seconds % 60)
    }
}

struct NeoRuntimeStepDetailSheet: View {
    let step: NeoRuntimeStep
    let liveReasoningBuffer: (UUID) -> LiveReasoningBuffer?
    let onOpenRelatedThread: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        NeoRuntimeNode(step: step)
                        NeoRuntimeFadingLabel(text: step.statusText, isRunning: step.state == .running)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(step.messages) { message in
                        detail(for: message)
                    }
                }
                .padding(24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(PalmiL10n.tr("common.close"), systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .tint(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(for message: PalmiChatMessage) -> some View {
        if let card = message.toolCall {
            if card.cardKind == .modelThink {
                section(PalmiL10n.tr("neo.runtime.reasoning")) {
                    NeoReasoningText(
                        messageID: message.id,
                        staticText: card.details.isEmpty ? card.summary : card.details,
                        liveBuffer: liveReasoningBuffer(message.id)
                    )
                }
            } else if card.cardKind == .phaseThought {
                section(PalmiL10n.tr("chat.phaseThought")) {
                    AssistantMarkdownContentView(markdown: card.details.isEmpty ? card.summary : card.details)
                }
            } else {
                toolDetail(card)
            }
        } else if let notice = message.contextCompaction {
            section(step.title) { Text(notice.localizedSummary).textSelection(.enabled) }
        } else {
            section(PalmiL10n.tr(step.kind == .completion ? "neo.runtime.reply" : "neo.runtime.explanation")) {
                AssistantMarkdownContentView(markdown: message.content)
            }
        }
    }

    @ViewBuilder
    private func toolDetail(_ card: PalmiToolCallCard) -> some View {
        if !card.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            section(PalmiL10n.tr("neo.runtime.overview")) {
                AssistantMarkdownContentView(markdown: card.summary)
            }
        }
        if !card.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            section(PalmiL10n.tr("neo.runtime.result")) {
                AssistantMarkdownContentView(markdown: card.details)
            }
        } else if step.state == .running {
            Text(PalmiL10n.tr("neo.runtime.awaitingResult"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        if !card.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            section(PalmiL10n.tr("tool.approval.arguments")) {
                SelectablePlainTextView(text: card.argumentsJSON)
            }
        }
        if let threadIDs = card.relatedThreadIDs, !threadIDs.isEmpty {
            section(PalmiL10n.tr("subagent.relatedThreads")) {
                ForEach(threadIDs, id: \.self) { threadID in
                    Button { onOpenRelatedThread(threadID) } label: {
                        Label(PalmiL10n.tr("subagent.openThread") + " · " + String(threadID.uuidString.prefix(8)),
                              systemImage: "arrow.up.right.square")
                    }
                    .tint(.primary)
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
