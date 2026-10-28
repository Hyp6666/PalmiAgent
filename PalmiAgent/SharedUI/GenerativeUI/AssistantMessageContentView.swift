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
        let parts = PalmiRichContentParser.parse(source, enabled: richContentVersion == 1, isStreaming: isStreaming)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(parts) { part in
                switch part.content {
                case .markdown(let markdown):
                    AssistantMarkdownContentView(markdown: markdownTransform(markdown))
                case .pending:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(PalmiL10n.tr("ui.generating")).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                case .invalid(let source, _):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(PalmiL10n.tr("ui.unavailable"), systemImage: "rectangle.slash").font(.subheadline)
                        DisclosureGroup(PalmiL10n.tr("ui.source")) {
                            ScrollView(.horizontal) {
                                Text(source).font(.caption.monospaced()).textSelection(.enabled)
                            }.frame(maxHeight: 220)
                        }.font(.caption)
                    }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                case .artifact(let validated):
                    PalmiUIArtifactCard(validated: validated, messageID: messageID,
                                        workspaceURL: workspaceURL, onRequestFollowUp: onRequestFollowUp)
                        .id("\(messageID.uuidString):\(validated.id)")
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PalmiUIArtifactCard: View {
    let validated: PalmiUIValidatedArtifact
    let messageID: UUID
    let workspaceURL: URL
    let onRequestFollowUp: (String) -> Void
    @State private var session: PalmiUIArtifactSession?

    var body: some View {
        Group {
            if let session {
                PalmiUIArtifactCardContent(session: session, onRequestFollowUp: onRequestFollowUp)
            } else { ProgressView().frame(maxWidth: .infinity).padding(20) }
        }.task(id: validated.id) {
            if session?.validated.id != validated.id {
                let value = PalmiUIArtifactSession(validated: validated, messageID: messageID, workspaceURL: workspaceURL)
                await value.loadIfNeeded()
                guard !Task.isCancelled else { return }
                session = value
            }
        }
    }
}

private struct PalmiUIArtifactCardContent: View {
    let session: PalmiUIArtifactSession
    @State private var expanded = false
    @State private var showingSource = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.palmiImagePreviewChanged) private var previewChanged
    let onRequestFollowUp: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: session.validated.artifact.kind == .native ? "slider.horizontal.3" : "square.stack.3d.up")
                    .foregroundStyle(.tint)
                Text(session.validated.artifact.title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                Button { captureAnd { expanded = true } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(PalmiL10n.tr("ui.expand"))
                    .disabled(!canCapture)
            }
            if !expanded {
                PalmiUIArtifactBody(session: session, isExpanded: false, onRequestFollowUp: onRequestFollowUp)
            } else {
                Color.clear.frame(height: 120)
            }
            toolbar
            if session.saveFailed { Text(PalmiL10n.tr("ui.saveFailed")).font(.caption).foregroundStyle(.secondary) }
            if session.snapshotFailed { Text(PalmiL10n.tr("ui.snapshotFailed")).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.08)))
        .onDisappear { session.flush(); previewChanged(false) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { _ = await session.captureLatestState(); session.flush() } }
        }
        .onChange(of: expanded) { _, _ in previewChanged(expanded || showingSource) }
        .onChange(of: showingSource) { _, _ in previewChanged(expanded || showingSource) }
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
                        Button(PalmiL10n.tr("ui.close")) {
                            Task {
                                _ = await session.captureLatestState()
                                session.flush(); expanded = false
                            }
                        }.disabled(session.actionPending)
                    }
                    ToolbarItem(placement: .bottomBar) {
                        HStack {
                            Button(PalmiL10n.tr("ui.reset")) { session.reset() }
                            Spacer()
                            Button(PalmiL10n.tr("ui.followUp")) {
                                captureAnd { onRequestFollowUp(session.followUpDraft()); expanded = false }
                            }.disabled(!canCapture)
                        }
                    }
                }
            }.interactiveDismissDisabled(session.validated.artifact.kind == .html)
                .onDisappear { session.flush() }
        }
        .sheet(isPresented: $showingSource) {
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    Text(session.validated.sourceJSON).font(.footnote.monospaced()).textSelection(.enabled).padding()
                }.navigationTitle(PalmiL10n.tr("ui.source"))
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(PalmiL10n.tr("ui.close")) { showingSource = false } } }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(PalmiL10n.tr("ui.reset")) { session.reset() }
            Button(PalmiL10n.tr("ui.source")) { showingSource = true }
            Spacer(minLength: 4)
            Button(PalmiL10n.tr("ui.followUp")) {
                captureAnd { onRequestFollowUp(session.followUpDraft()); expanded = false }
            }.disabled(!canCapture)
        }.font(.caption.weight(.medium)).buttonStyle(.plain).foregroundStyle(.tint)
    }

    private var canCapture: Bool {
        !session.actionPending && (session.validated.artifact.kind == .native || session.snapshotAvailable)
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
            return AnyView(VStack(alignment: .leading, spacing: 12) { children }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12)))
        case .text:
            return AnyView(Text(node.text ?? "").font(.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true))
        case .metric:
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                Text(node.label ?? "").font(.caption).foregroundStyle(.secondary)
                Text(formatted(node.expression?.evaluate(in: session.state))).font(.title2.weight(.semibold))
                    .monospacedDigit().contentTransition(.numericText())
            })
        case .slider:
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                HStack { Text(node.label ?? ""); Spacer(); Text(formatted(session.state[node.stateKey ?? ""]?.number)).monospacedDigit() }
                    .font(.subheadline)
                Slider(value: numberBinding, in: (node.minimum ?? 0)...(node.maximum ?? 1), step: node.step ?? 0.01)
                    .accessibilityLabel(node.label ?? "")
            })
        case .toggle:
            return AnyView(Toggle(node.label ?? "", isOn: boolBinding).font(.subheadline))
        case .select:
            return AnyView(Picker(node.label ?? "", selection: stringBinding) {
                ForEach(node.options ?? [], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu))
        case .textField:
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                Text(node.label ?? "").font(.caption).foregroundStyle(.secondary)
                TextField(node.text ?? "", text: stringBinding).textFieldStyle(.roundedBorder)
            })
        case .chart:
            return AnyView(Chart {
                ForEach(Array((node.points ?? []).enumerated()), id: \.offset) { _, point in
                    if let value = point.value.evaluate(in: session.state) {
                        if node.chartStyle == "bar" {
                            BarMark(x: .value("Category", point.label), y: .value("Value", value))
                        } else {
                            LineMark(x: .value("Category", point.label), y: .value("Value", value))
                            PointMark(x: .value("Category", point.label), y: .value("Value", value))
                        }
                    }
                }
            }.frame(height: dynamicTypeSize.isAccessibilitySize ? 280 : 220)
                .accessibilityLabel(node.label ?? session.validated.artifact.title))
        case .divider: return AnyView(Divider())
        case .button:
            return AnyView(Button(node.label ?? "") {
                switch node.action {
                case .reset: session.reset()
                case .continueConversation:
                    session.flush(); onRequestFollowUp(session.followUpDraft(prefix: node.followUp))
                case nil: break
                }
            }.buttonStyle(.bordered))
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
