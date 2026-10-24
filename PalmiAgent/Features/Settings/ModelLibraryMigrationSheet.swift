import SwiftUI

/// 首次升级的迁移反馈：展示旧方案如何归入模型库、主模型从哪里来、轻模型与多模态槽位去了哪里，并提供命名机会。
/// 只读模型库状态并写备注；重放这段呈现不会改变任何迁移数据。
struct ModelLibraryMigrationSheet: View {
    let library: ModelLibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var phase = 0
    @State private var labels: [UUID: String] = [:]
    @State private var errorMessage: String?

    private var receipt: ModelLibraryMigrationReceipt? { library.state.migrationReceipt }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    flow
                    if phase >= 3 { outcomes.transition(.move(edge: .bottom).combined(with: .opacity)) }
                    if phase >= 4 { naming.transition(.opacity) }
                    if phase >= 4 { compatibilityNote.transition(.opacity) }
                }
                .padding(20)
            }
            .navigationTitle(PalmiL10n.tr("ml.migration.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(PalmiL10n.tr("common.done")) { finish() }
                }
            }
            .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .task { await play() }
        }
        .interactiveDismissDisabled(phase < 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: phase)
            Text(PalmiL10n.tr("ml.migration.headline")).font(.title2.weight(.bold))
            Text(PalmiL10n.tr("ml.migration.subtitle")).foregroundStyle(.secondary)
        }
    }

    private var flow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(PalmiL10n.tr("ml.migration.oldPlans")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(receipt?.importedPlans ?? [], id: \.planID) { plan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if plan.wasActive { Text(PalmiL10n.tr("ml.migration.wasActive")).font(.caption2).foregroundStyle(.tint) }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(phase >= 2 ? 0.35 : 1), in: .rect(cornerRadius: 12))
                    .opacity(phase >= 2 ? 0.45 : 1)
                }
                if receipt?.importedPlans.isEmpty ?? true {
                    Text(PalmiL10n.tr("ml.migration.noPlans")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .opacity(phase >= 1 ? 1 : 0)
                .offset(x: phase >= 1 ? 0 : -8)
                .padding(.top, 28)

            VStack(alignment: .leading, spacing: 8) {
                Text(PalmiL10n.tr("ml.library.title")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(library.state.connections.enumerated()), id: \.element.id) { index, connection in
                    let count = library.state.models.filter { $0.connectionID == connection.id }.count
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(PalmiL10n.tr("ml.connection.modelCount", count)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 12))
                    .opacity(phase >= 2 ? 1 : 0)
                    .scaleEffect(phase >= 2 ? 1 : 0.92)
                    .animation(.spring(duration: 0.45).delay(Double(index) * 0.06), value: phase)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var outcomes: some View {
        VStack(alignment: .leading, spacing: 10) {
            outcomeRow(icon: "star.fill", title: PalmiL10n.tr("ml.mainModel"),
                       value: ModelLibraryPresentation.mainModelStatus(library).title,
                       detail: sourceText)
            outcomeRow(icon: "eye", title: PalmiL10n.tr("ml.tool.vision"), value: bindingText(library.state.toolBindings.vision),
                       detail: PalmiL10n.tr("ml.migration.visionDetail"))
            outcomeRow(icon: "checkmark.shield", title: PalmiL10n.tr("ml.tool.review"), value: bindingText(library.state.toolBindings.permissionReview),
                       detail: PalmiL10n.tr("ml.migration.reviewDetail"))
            ForEach(receipt?.notes ?? [], id: \.self) { note in
                ModelLibraryStatusLine(text: note, isProblem: true)
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }

    private func outcomeRow(icon: String, title: String, value: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var naming: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PalmiL10n.tr("ml.migration.naming")).font(.headline)
            Text(PalmiL10n.tr("ml.migration.namingDetail")).font(.footnote).foregroundStyle(.secondary)
            ForEach(library.state.connections.filter { $0.userLabel == nil && $0.chatGPTAccount == nil }) { connection in
                TextField(ModelLibraryURLDisplay.safeDisplay(connection.endpoints.inputAddress), text: Binding(
                    get: { labels[connection.id] ?? "" },
                    set: { labels[connection.id] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var compatibilityNote: some View {
        Label(PalmiL10n.tr("ml.migration.compatibility"), systemImage: "arrow.uturn.backward.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var sourceText: String {
        switch receipt?.defaultMainSource {
        case "v2.activePlan": PalmiL10n.tr("ml.migration.source.plan")
        case "preV2.activePlan", "preV2": PalmiL10n.tr("ml.migration.source.preV2")
        case "apiProfile.active": PalmiL10n.tr("ml.migration.source.apiProfile")
        default: PalmiL10n.tr("ml.migration.source.none")
        }
    }

    private func bindingText(_ binding: ToolModelBinding) -> String {
        switch binding {
        case .followMainModel: PalmiL10n.tr("ml.tool.followMain")
        case .model(let id): library.state.model(id)?.title ?? PalmiL10n.tr("ml.binding.invalid")
        }
    }

    private func play() async {
        for next in 1...4 {
            try? await Task.sleep(for: .milliseconds(next == 1 ? 450 : 650))
            withAnimation(.spring(duration: 0.5)) { phase = next }
        }
    }

    private func finish() {
        do {
            for (id, text) in labels {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                try library.updateConnection(id, label: .some(text), endpoints: nil, newAPIKey: nil, clearAPIKey: false)
            }
            library.markMigrationPresented()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
