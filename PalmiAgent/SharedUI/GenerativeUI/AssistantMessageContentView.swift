import SwiftUI
import Charts
import UIKit

struct AssistantMessageContentView: View {
    let messageID: UUID
    let source: String
    let isStreaming: Bool
    let richContentVersion: Int?
    let workspaceURL: URL
    var markdownTransform: (String) -> String = { $0 }
    let onRequestFollowUp: (String) -> Void

    var body: some View {
        let parts = PalmiRichContentParseCache.parts(source, enabled: richContentVersion == 1, isStreaming: isStreaming)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(parts) { part in
                switch part.content {
                case .markdown(let markdown):
                    AssistantMarkdownContentView(markdown: markdownTransform(markdown))
                case .pending:
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                case .invalid(let source, _):
                    // 组件无法渲染时只保留模型给出的文字摘要，不暴露 JSON 源码。
                    if let summary = PalmiRichContentParseCache.fallbackSummary(source) {
                        AssistantMarkdownContentView(markdown: summary)
                    }
                case .artifact(let validated):
                    PalmiUIArtifactInline(validated: validated, messageID: messageID,
                                          workspaceURL: workspaceURL, onRequestFollowUp: onRequestFollowUp)
                        .id("\(messageID.uuidString):\(validated.id)")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 解析结果缓存：列表滚动、其他消息流式刷新时不重复解析/校验同一段正文。
@MainActor
private enum PalmiRichContentParseCache {
    private final class Box { let parts: [PalmiRichContentPart]; init(_ parts: [PalmiRichContentPart]) { self.parts = parts } }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>(); cache.countLimit = 160; return cache
    }()

    static func parts(_ source: String, enabled: Bool, isStreaming: Bool) -> [PalmiRichContentPart] {
        let key = "\(enabled ? 1 : 0)\(isStreaming ? 1 : 0)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit.parts }
        let parts = PalmiRichContentParser.parse(source, enabled: enabled, isStreaming: isStreaming)
        cache.setObject(Box(parts), forKey: key)
        return parts
    }

    static func fallbackSummary(_ source: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any],
              let summary = object["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(summary.prefix(1_000))
    }
}

/// 语义色与调色板。全部使用系统动态色，浅色/深色模式自动适配。
enum PalmiUITone {
    static func color(_ tone: String?) -> Color? {
        switch tone?.lowercased() {
        case "positive", "success", "correct", "green": .green
        case "negative", "danger", "error", "wrong", "red": .red
        case "warning", "caution", "orange": .orange
        case "info", "blue": .blue
        case "accent", "purple": .purple
        case "neutral", "gray", "grey": .gray
        case "yellow": .yellow
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "indigo": .indigo
        case "pink": .pink
        case "brown": .brown
        default: nil
        }
    }

    static func defaultIcon(_ tone: String?) -> String {
        switch tone?.lowercased() {
        case "positive", "success", "correct", "green", "mint": "checkmark.circle.fill"
        case "negative", "danger", "error", "wrong", "red": "xmark.circle.fill"
        case "warning", "caution", "orange", "yellow": "exclamationmark.triangle.fill"
        case "info", "blue", "cyan", "teal", "indigo": "info.circle.fill"
        default: "lightbulb.fill"
        }
    }
}

/// 交互会话缓存：消息滑出屏幕再滑回来时直接复用，不再先显示占位再异步重建，避免列表高度跳变。
@MainActor
enum PalmiUIArtifactSessionCache {
    private static let cache: NSCache<NSString, PalmiUIArtifactSession> = {
        let cache = NSCache<NSString, PalmiUIArtifactSession>(); cache.countLimit = 64; return cache
    }()

    static func key(messageID: UUID, artifactID: String) -> NSString { "\(messageID.uuidString):\(artifactID)" as NSString }
    static func session(for key: NSString) -> PalmiUIArtifactSession? { cache.object(forKey: key) }
    static func store(_ session: PalmiUIArtifactSession, for key: NSString) { cache.setObject(session, forKey: key) }
}

private struct PalmiUIArtifactInline: View {
    let validated: PalmiUIValidatedArtifact
    let messageID: UUID
    let workspaceURL: URL
    let onRequestFollowUp: (String) -> Void
    @State private var session: PalmiUIArtifactSession?

    init(validated: PalmiUIValidatedArtifact, messageID: UUID, workspaceURL: URL, onRequestFollowUp: @escaping (String) -> Void) {
        self.validated = validated
        self.messageID = messageID
        self.workspaceURL = workspaceURL
        self.onRequestFollowUp = onRequestFollowUp
        let key = PalmiUIArtifactSessionCache.key(messageID: messageID, artifactID: validated.id)
        var initial = PalmiUIArtifactSessionCache.session(for: key)
        // 原生组件不依赖已保存状态即可排版：同步创建，首帧就是最终高度，已保存状态随后载入。
        if initial == nil, validated.artifact.kind == .native {
            let created = PalmiUIArtifactSession(validated: validated, messageID: messageID, workspaceURL: workspaceURL)
            PalmiUIArtifactSessionCache.store(created, for: key)
            initial = created
        }
        _session = State(initialValue: initial)
    }

    var body: some View {
        Group {
            if let session {
                PalmiUIArtifactContent(session: session, onRequestFollowUp: onRequestFollowUp)
            } else {
                Color.clear.frame(height: PalmiHTMLHeightCache.height(for: validated.id, expanded: false) ?? 44)
            }
        }.task(id: validated.id) {
            if let session, session.validated.id == validated.id {
                await session.loadIfNeeded()
                return
            }
            let value = PalmiUIArtifactSession(validated: validated, messageID: messageID, workspaceURL: workspaceURL)
            await value.loadIfNeeded()
            guard !Task.isCancelled else { return }
            PalmiUIArtifactSessionCache.store(value, for: PalmiUIArtifactSessionCache.key(messageID: messageID, artifactID: validated.id))
            session = value
        }
    }
}

/// 交互内容直接嵌在正文流里：没有外框、标题栏和工具条。
/// HTML 小应用只在右上角保留一个展开图标。
private struct PalmiUIArtifactContent: View {
    let session: PalmiUIArtifactSession
    @State private var expanded = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.palmiImagePreviewChanged) private var previewChanged
    let onRequestFollowUp: (String) -> Void

    private var isHTML: Bool { session.validated.artifact.kind == .html }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // 展开图标单独占一行放在内容上方，不压在交互内容上。
            if isHTML {
                Button { captureAnd { expanded = true } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PalmiL10n.tr("ui.expand"))
                .disabled(!canCapture || expanded)
            }
            if expanded {
                Color.clear.frame(height: 120)
            } else {
                PalmiUIArtifactBody(session: session, isExpanded: false, onRequestFollowUp: onRequestFollowUp)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.validated.artifact.title)
        .onDisappear { session.flush(); previewChanged(false) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { _ = await session.captureLatestState(); session.flush() } }
        }
        .onChange(of: expanded) { _, value in previewChanged(value) }
        .sheet(isPresented: $expanded) {
            NavigationStack {
                ScrollView {
                    PalmiUIArtifactBody(session: session, isExpanded: true, onRequestFollowUp: onRequestFollowUp)
                        .padding(16)
                }
                .navigationTitle(session.validated.artifact.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(PalmiL10n.tr("ui.close"), systemImage: "xmark") {
                            Task {
                                _ = await session.captureLatestState()
                                session.flush(); expanded = false
                            }
                        }
                        .labelStyle(.iconOnly)
                        .disabled(session.actionPending)
                    }
                }
            }.interactiveDismissDisabled(isHTML)
                .onDisappear { session.flush() }
        }
    }

    private var canCapture: Bool {
        !session.actionPending && (!isHTML || session.snapshotAvailable)
    }

    private func captureAnd(_ action: @escaping () -> Void) {
        Task { if await session.captureLatestState() { action() } }
    }
}

private struct PalmiUIArtifactBody: View {
    let session: PalmiUIArtifactSession
    let isExpanded: Bool
    let onRequestFollowUp: (String) -> Void

    var body: some View {
        if session.validated.artifact.kind == .native {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(session.validated.artifact.elements ?? []) { node in
                    PalmiNativeUINodeView(node: node, session: session, onRequestFollowUp: onRequestFollowUp)
                }
            }
        } else {
            PalmiHTMLArtifactView(session: session, expanded: isExpanded)
                .id(session.reloadID)
        }
    }
}

private struct PalmiNativeUINodeView: View {
    let node: PalmiUINode
    let session: PalmiUIArtifactSession
    let onRequestFollowUp: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View { content }

    private var tone: Color? { PalmiUITone.color(node.tone) }

    private var content: AnyView {
        switch node.type {
        case .column:
            return AnyView(VStack(alignment: .leading, spacing: 12) { children })
        case .row:
            return AnyView(ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { children }
                VStack(alignment: .leading, spacing: 12) { children }
            })
        case .card:
            let tint = tone ?? .secondary
            return AnyView(VStack(alignment: .leading, spacing: 12) { children }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(tone == nil ? 0.08 : 0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    if tone != nil {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 1)
                    }
                })
        case .callout:
            let tint = tone ?? .blue
            return AnyView(HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: node.icon ?? PalmiUITone.defaultIcon(node.tone))
                    .foregroundStyle(tint)
                    .font(.body.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    if let label = node.label, !label.isEmpty {
                        Text(label).font(.headline).foregroundStyle(tint)
                    }
                    if let text = node.text, !text.isEmpty {
                        Text(text).font(.body).foregroundStyle(.primary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1)))
        case .badge:
            let tint = tone ?? .accentColor
            return AnyView(HStack(spacing: 4) {
                if let icon = node.icon { Image(systemName: icon) }
                Text(node.label ?? "")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule()))
        case .text:
            return AnyView(Text(node.text ?? "").font(textFont).foregroundStyle(textColor).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true))
        case .metric:
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if let icon = node.icon { Image(systemName: icon).foregroundStyle(tone ?? .secondary) }
                    Text(node.label ?? "").foregroundStyle(.secondary)
                }.font(.footnote.weight(.medium))
                Text(formatted(node.expression?.evaluate(in: session.state)))
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(tone ?? .primary)
                    .monospacedDigit().contentTransition(.numericText())
            })
        case .progress:
            let minimum = node.minimum ?? 0, maximum = node.maximum ?? 100
            let value = node.expression?.evaluate(in: session.state)
            let fraction = value.map { min(max(($0 - minimum) / (maximum - minimum), 0), 1) } ?? 0
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(node.label ?? "")
                    Spacer()
                    Text(formatted(value)).monospacedDigit().foregroundStyle(tone ?? .secondary)
                }.font(.subheadline)
                ProgressView(value: fraction).tint(tone ?? .accentColor)
            })
        case .slider:
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(node.label ?? "")
                    Spacer()
                    Text(formatted(session.state[node.stateKey ?? ""]?.number)).monospacedDigit()
                        .foregroundStyle(tone ?? .primary).fontWeight(.semibold)
                }.font(.subheadline)
                Slider(value: numberBinding, in: (node.minimum ?? 0)...(node.maximum ?? 1), step: node.step ?? 0.01)
                    .tint(tone ?? .accentColor)
                    .accessibilityLabel(node.label ?? "")
            })
        case .toggle:
            return AnyView(Toggle(node.label ?? "", isOn: boolBinding).font(.subheadline).tint(tone ?? .green))
        case .select:
            return AnyView(HStack {
                Text(node.label ?? "").font(.subheadline)
                Spacer(minLength: 8)
                Picker(node.label ?? "", selection: stringBinding) {
                    ForEach(node.options ?? [], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).labelsHidden().tint(tone ?? .accentColor)
            })
        case .textField:
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                Text(node.label ?? "").font(.footnote).foregroundStyle(.secondary)
                TextField(node.text ?? "", text: stringBinding).textFieldStyle(.roundedBorder)
            })
        case .chart:
            return AnyView(chart)
        case .divider: return AnyView(Divider())
        case .button:
            return AnyView(Button {
                switch node.action {
                case .reset: session.reset()
                case .continueConversation:
                    session.flush(); onRequestFollowUp(session.followUpDraft(prefix: node.followUp))
                case nil: break
                }
            } label: {
                if let icon = node.icon { Label(node.label ?? "", systemImage: icon) } else { Text(node.label ?? "") }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(tone ?? .accentColor))
        }
    }

    private var chart: some View {
        let points = Array((node.points ?? []).enumerated())
        let isBar = node.chartStyle == "bar"
        // 颜色完全由模型给出的 tone 决定；未给出时使用系统默认强调色，不做任何自动配色。
        let lineTint = tone ?? .accentColor
        return VStack(alignment: .leading, spacing: 8) {
            if let label = node.label, !label.isEmpty {
                Text(label).font(.subheadline.weight(.semibold))
            }
            Chart {
                ForEach(points, id: \.offset) { _, point in
                    if let value = point.value.evaluate(in: session.state) {
                        if isBar {
                            BarMark(x: .value("Category", point.label), y: .value("Value", value))
                                .foregroundStyle(PalmiUITone.color(point.tone) ?? lineTint)
                                .cornerRadius(6)
                        } else {
                            AreaMark(x: .value("Category", point.label), y: .value("Value", value))
                                .foregroundStyle(LinearGradient(colors: [lineTint.opacity(0.28), lineTint.opacity(0.02)],
                                                                startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("Category", point.label), y: .value("Value", value))
                                .foregroundStyle(lineTint)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .interpolationMethod(.catmullRom)
                            PointMark(x: .value("Category", point.label), y: .value("Value", value))
                                .foregroundStyle(PalmiUITone.color(point.tone) ?? lineTint)
                        }
                    }
                }
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 280 : 220)
            .accessibilityLabel(node.label ?? session.validated.artifact.title)
        }
    }

    private var textFont: Font {
        switch node.style?.lowercased() {
        case "title": .title3.weight(.bold)
        case "headline": .headline
        case "caption", "footnote": .footnote
        default: .body
        }
    }

    private var textColor: Color {
        if let tone { return tone }
        switch node.style?.lowercased() {
        case "caption", "footnote": return .secondary
        default: return .primary
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(node.children ?? []) {
            PalmiNativeUINodeView(node: $0, session: session, onRequestFollowUp: onRequestFollowUp)
        }
    }

    private var numberBinding: Binding<Double> {
        Binding(get: { session.state[node.stateKey ?? ""]?.number ?? node.minimum ?? 0 },
                set: { session.set(.number($0), for: node.stateKey ?? "") })
    }
    private var boolBinding: Binding<Bool> {
        Binding(get: { session.state[node.stateKey ?? ""]?.boolean ?? false },
                set: { session.set(.bool($0), for: node.stateKey ?? "") })
    }
    private var stringBinding: Binding<String> {
        Binding(get: { session.state[node.stateKey ?? ""]?.string ?? "" },
                set: { session.set(.string(String($0.prefix(1_000))), for: node.stateKey ?? "") })
    }
    private func formatted(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.*f", node.decimals ?? 2, value) + (node.suffix ?? "")
    }
}
