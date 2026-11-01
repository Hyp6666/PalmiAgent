import SwiftUI

/// 首次升级的迁移反馈：同一页对照 26.10 旧方案的三个槽位与 26.11 的默认模型和工具模型。
/// 只读模型库状态；重放这段呈现不会改变任何迁移数据。
struct ModelLibraryMigrationSheet: View {
    let library: ModelLibraryStore
    @Environment(\.dismiss) private var dismiss

    private var receipt: ModelLibraryMigrationReceipt? { library.state.migrationReceipt }

    /// 旧版只有当前方案决定实际使用的模型；没有标记时取第一个方案。
    private var previousPlan: ModelLibraryMigrationReceipt.ImportedPlan? {
        receipt?.importedPlans.first(where: \.wasActive) ?? receipt?.importedPlans.first
    }

    var body: some View {
        NavigationStack {
            List {
                Section(previousPlan.map { "26.10 · \($0.name)" } ?? "26.10") {
                    row("star", PalmiL10n.tr("model.slot.primary"), modelTitle(previousPlan?.primaryModelID))
                    row("eye", PalmiL10n.tr("model.role.multimodal"), modelTitle(previousPlan?.multimodalModelID))
                    row("checkmark.shield", PalmiL10n.tr("model.slot.lightweight"), modelTitle(previousPlan?.lightweightModelID))
                }
                Section("26.11") {
                    row("star", PalmiL10n.tr("ml.mainModel"), ModelLibraryPresentation.mainModelStatus(library).title)
                    row("eye", PalmiL10n.tr("tool.facade.vision"), bindingText(library.state.toolBindings.vision))
                    row("checkmark.shield", PalmiL10n.tr("ml.tool.review"), bindingText(library.state.toolBindings.permissionReview))
                }
                if let notes = receipt?.localizedNotes, !notes.isEmpty {
                    Section {
                        ForEach(notes, id: \.self) { note in
                            Label(note, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle(PalmiL10n.tr("ml.migration.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(PalmiL10n.tr("common.done")) { dismiss() }
                }
            }
        }
        .onDisappear { library.markMigrationPresented() }
    }

    private func row(_ icon: String, _ title: String, _ value: String) -> some View {
        LabeledContent {
            Text(value).lineLimit(1)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func modelTitle(_ id: UUID?) -> String {
        guard let id else { return "—" }
        return library.state.model(id)?.title ?? PalmiL10n.tr("ml.binding.invalid")
    }

    private func bindingText(_ binding: ToolModelBinding) -> String {
        switch binding {
        case .followMainModel: PalmiL10n.tr("ml.tool.followMain")
        case .model(let id): library.state.model(id)?.title ?? PalmiL10n.tr("ml.binding.invalid")
        }
    }
}
