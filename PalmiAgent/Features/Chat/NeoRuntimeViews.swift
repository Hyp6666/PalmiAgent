import SwiftUI
import UIKit

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
    let selection: WorkspaceSelection?

    @State private var presentation: NeoRuntimePresentation?
    @Environment(BrowserOperatorService.self) private var browser: BrowserOperatorService?

    private var isLive: Bool { isCurrentTurn && header.finishedAt == nil }

    private var steps: [NeoRuntimeStep] {
        NeoRuntimeTimeline.build(
            messages: messages, finalMessage: finalMessage, isLive: isLive,
            liveReasoningIDs: Set(messages.filter { liveReasoningBuffer($0.id) != nil }.map(\.id)),
            streamingMessageID: streamingMessageID, completionID: headerID,
            browserProgress: browser.map { Array($0.runtimeProgress.values) } ?? [], selection: selection
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
                // 撑满宽度：否则半屏时内容按自身宽度居中，只露出中间一条白底。
                .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 纯思考步骤：整页使用原生滚动文本视图，长思维链只排版可见部分，打开和滚动都不卡。
    private var reasoningOnlyMessage: PalmiChatMessage? {
        guard step.messages.count == 1, let message = step.messages.first,
              message.toolCall?.cardKind == .modelThink else { return nil }
        return message
    }

    var body: some View {
        NavigationStack {
            Group {
                if let message = reasoningOnlyMessage, let card = message.toolCall {
                    NeoReasoningScrollText(
                        messageID: message.id,
                        staticText: card.details.isEmpty ? card.summary : card.details,
                        liveBuffer: liveReasoningBuffer(message.id)
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    detailScroll
                }
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

    private var detailScroll: some View {
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
        // 顺序：工具输入 → （浏览器步骤）→ 工具输出。
        if card.toolName == "browser", let progress = step.browserProgress {
            section(PalmiL10n.tr("neo.runtime.toolInput")) {
                Text(progress.task).textSelection(.enabled)
            }
            section(PalmiL10n.tr("browser.runtime.steps")) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(progress.steps) { browserStep in
                        Text(browserStep.historyLine)
                            .font(.footnote)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(browserStep.failed ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(browserStep.historyLine)
                    }
                }
            }
            if card.isRunning != true, !card.details.isEmpty {
                section(PalmiL10n.tr("neo.runtime.toolOutput")) {
                    Text(card.details).textSelection(.enabled)
                }
            }
        } else {
        if !card.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            section(PalmiL10n.tr("neo.runtime.toolInput")) {
                SelectablePlainTextView(text: card.argumentsJSON)
            }
        }
        if !card.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            section(PalmiL10n.tr("neo.runtime.toolOutput")) {
                AssistantMarkdownContentView(markdown: card.details)
            }
        } else if step.state == .running {
            Text(PalmiL10n.tr("neo.runtime.awaitingResult"))
                .font(.subheadline).foregroundStyle(.secondary)
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

/// 思维链全文：自身可滚动的 TextKit 1 文本视图，开启非连续排版；
/// 实时思考只追加新增片段，用户停在底部时自动跟随。
struct NeoReasoningScrollText: View {
    let messageID: UUID
    let staticText: String
    let liveBuffer: LiveReasoningBuffer?

    var body: some View {
        NeoReasoningScrollTextView(messageID: messageID, staticText: staticText,
                                   liveBuffer: liveBuffer, revision: liveBuffer?.revision ?? 0)
    }
}

private struct NeoReasoningScrollTextView: UIViewRepresentable {
    let messageID: UUID
    let staticText: String
    let liveBuffer: LiveReasoningBuffer?
    let revision: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 40, right: 20)
        view.textContainer.lineFragmentPadding = 0
        view.layoutManager.allowsNonContiguousLayout = true
        view.dataDetectorTypes = []
        context.coordinator.apply(to: view, owner: self)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.apply(to: uiView, owner: self)
    }

    @MainActor final class Coordinator {
        private var streamID: UUID?
        private var consumedChunks = 0
        private var wasLive = false
        private var appliedStatic: String?

        private var attributes: [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            return [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label, .paragraphStyle: style]
        }

        func apply(to view: UITextView, owner: NeoReasoningScrollTextView) {
            if streamID != owner.messageID {
                streamID = owner.messageID
                replace(view, text: owner.liveBuffer?.snapshot() ?? owner.staticText)
                appliedStatic = owner.liveBuffer == nil ? owner.staticText : nil
                consumedChunks = owner.liveBuffer?.chunkCount ?? 0
                wasLive = owner.liveBuffer != nil
                return
            }
            if let buffer = owner.liveBuffer {
                let chunks = buffer.chunks(from: consumedChunks)
                consumedChunks = buffer.chunkCount
                wasLive = true
                guard !chunks.isEmpty else { return }
                let following = isNearBottom(view)
                view.textStorage.beginEditing()
                for chunk in chunks { view.textStorage.append(NSAttributedString(string: chunk, attributes: attributes)) }
                view.textStorage.endEditing()
                if following { scrollToBottom(view) }
            } else if appliedStatic != owner.staticText {
                // 实时缓冲结束后以持久化全文为准；内容一致时不重排。
                wasLive = false
                appliedStatic = owner.staticText
                if view.textStorage.string != owner.staticText { replace(view, text: owner.staticText) }
            }
        }

        private func replace(_ view: UITextView, text: String) {
            view.textStorage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }

        private func isNearBottom(_ view: UITextView) -> Bool {
            view.contentOffset.y + view.bounds.height >= view.contentSize.height - 80
        }

        private func scrollToBottom(_ view: UITextView) {
            let y = max(-view.adjustedContentInset.top, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
            view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }
}
