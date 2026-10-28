import SwiftUI
import UniformTypeIdentifiers

enum SkillCatalogMode: Equatable {
    case global
    case project(WorkspaceProjectRecord)

    var title: String {
        switch self {
        case .global:
            PalmiL10n.tr("skill.title")
        case .project(let project):
            PalmiL10n.tr("skill.projectTitle", project.name)
        }
    }

    var importButtonTitle: String {
        switch self {
        case .global:
            PalmiL10n.tr("skill.importFile")
        case .project:
            PalmiL10n.tr("skill.importToProject")
        }
    }
}

struct SkillCatalogScreen: View {
    @Bindable var registry: SkillRegistry
    let mode: SkillCatalogMode
    @State private var isImporting = false
    @State private var importErrorMessage: String?
    @State private var presentedSkill: SkillPackage?

    private let allowedContentTypes: [UTType] = [
        .zip,
        .plainText,
        .text,
        UTType(filenameExtension: "md") ?? .plainText
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                overviewCard

                if let statusText = registry.statusMessage, !statusText.isEmpty {
                    statusBanner(text: statusText, isError: false)
                }

                if let importErrorMessage {
                    statusBanner(text: importErrorMessage, isError: true)
                }

                ForEach(displaySections) { section in
                    SkillSectionBlock(
                        registry: registry,
                        title: section.title,
                        packages: section.packages,
                        onOpenSkill: { presentedSkill = $0 }
                    ) { message in
                        importErrorMessage = message
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(mode.importButtonTitle) {
                    isImporting = true
                }
            }
        }
        .task(id: reloadKey) {
            refresh()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(item: $presentedSkill) { skill in
            NavigationStack {
                SkillDetailScreen(
                    registry: registry,
                    skill: skill,
                    onDeleted: {
                        presentedSkill = nil
                    },
                    onError: { message in
                        importErrorMessage = message
                    }
                )
            }
        }
    }

    private var reloadKey: String {
        switch mode {
        case .global:
            return "global"
        case .project(let project):
            return "project-\(project.id.uuidString)"
        }
    }

    private var displaySections: [SkillSectionData] {
        switch mode {
        case .global:
            let builtIn = registry.globalSkills.filter { $0.source == .builtIn }
            let imported = registry.globalSkills.filter { $0.source != .builtIn }
            return [
                SkillSectionData(title: PalmiL10n.tr("skill.section.system"), packages: builtIn),
                SkillSectionData(title: PalmiL10n.tr("skill.section.global"), packages: imported)
            ]
            .filter { !$0.packages.isEmpty }

        case .project(let project):
            let builtIn = registry.globalSkills.filter { $0.source == .builtIn }
            let globalImported = registry.globalSkills.filter { $0.source != .builtIn }
            let projectSkills = registry.projectSkills(for: project.id)
            return [
                SkillSectionData(title: PalmiL10n.tr("skill.section.system"), packages: builtIn),
                SkillSectionData(title: PalmiL10n.tr("skill.section.global"), packages: globalImported),
                SkillSectionData(title: PalmiL10n.tr("skill.section.currentProject"), packages: projectSkills)
            ]
            .filter { !$0.packages.isEmpty }
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .global ? PalmiL10n.tr("skill.overview.global") : PalmiL10n.tr("skill.overview.project"))
            Text(PalmiL10n.tr("skill.overview.importSupport"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    private func statusBanner(text: String, isError: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private func refresh() {
        importErrorMessage = nil
        do {
            try registry.reloadGlobalSkills()
            if case .project(let project) = mode {
                try registry.reloadProjectSkills(for: project.id)
            }
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        importErrorMessage = nil

        guard case .success(let urls) = result else {
            if case .failure(let error) = result {
                importErrorMessage = error.localizedDescription
            }
            return
        }

        guard let url = urls.first else { return }

        do {
            switch mode {
            case .global:
                try registry.importGlobalSkill(from: url)
            case .project(let project):
                try registry.importProjectSkill(from: url, projectID: project.id)
            }
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }
}

struct SkillInlineStrip: View {
    let packages: [SkillPackage]
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(PalmiL10n.tr("skill.title"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(PalmiL10n.tr("common.viewAll")) {
                    onOpen()
                }
                .font(.caption.weight(.medium))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(packages) { skill in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(skill.scope.localizedDisplayTitle)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(skill.scope == .global ? .blue : .mint)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

private struct SkillSectionData: Identifiable {
    let title: String
    let packages: [SkillPackage]

    var id: String { title }
}

private struct SkillSectionBlock: View {
    @Bindable var registry: SkillRegistry
    let title: String
    let packages: [SkillPackage]
    let onOpenSkill: (SkillPackage) -> Void
    let onToggleError: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)

            LazyVStack(spacing: 8) {
                ForEach(packages) { skill in
                    SkillCard(
                        skill: skill,
                        onOpen: { onOpenSkill(skill) },
                        isEnabled: Binding(
                            get: { skill.isEnabled },
                            set: { newValue in
                                do {
                                    try registry.setEnabled(newValue, for: skill)
                                } catch {
                                    onToggleError(error.localizedDescription)
                                }
                            }
                        )
                    )
                }
            }
        }
    }
}

private struct SkillCard: View {
    let skill: SkillPackage
    let onOpen: () -> Void
    @Binding var isEnabled: Bool

    private var badgeTint: Color {
        skill.source == .builtIn ? .indigo : .blue
    }

    private var badgeText: String {
        skill.source == .builtIn ? PalmiL10n.tr("skill.source.builtIn") : PalmiL10n.tr("skill.source.imported")
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    skillPill(badgeText, tint: badgeTint)

                    Text(skill.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if skill.isAlwaysEnabled {
                Text(PalmiL10n.tr("skill.system.required"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
            } else {
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .tint(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    private func skillPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tint.opacity(0.12))
            )
    }
}

/// 技能详情：像文件夹一样浏览技能包，点文件用工作区同一套预览。
private struct SkillDetailScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var registry: SkillRegistry
    let skill: SkillPackage
    let onDeleted: () -> Void
    let onError: (String) -> Void
    @State private var isDeleting = false

    var body: some View {
        SkillFolderScreen(rootURL: skill.packageURL, relativePath: nil, title: skill.name)
            .toolbar {
                if skill.source != .builtIn {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) { isDeleting = true } label: { Image(systemName: "trash") }
                            .accessibilityLabel(PalmiL10n.tr("common.delete"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(PalmiL10n.tr("common.done")) { dismiss() }
                }
            }
            .confirmationDialog(skill.name, isPresented: $isDeleting, titleVisibility: .visible) {
                Button(PalmiL10n.tr("common.delete"), role: .destructive) { deleteSkill() }
            }
    }

    private func deleteSkill() {
        do {
            try registry.deleteSkill(skill)
            onDeleted()
            dismiss()
        } catch {
            onError(error.localizedDescription)
        }
    }
}

/// 技能包里的一层目录。只读：不提供新建、重命名或删除。
private struct SkillFolderScreen: View {
    let rootURL: URL
    let relativePath: String?
    let title: String
    @State private var previewedFile: WorkspacePreviewFile?
    @State private var errorMessage: String?

    private var nodes: [WorkspaceFileNode] {
        let directory = relativePath.map { rootURL.appendingPathComponent($0) } ?? rootURL
        return SkillFileNodeBuilder.nodes(in: directory, root: rootURL)
    }

    var body: some View {
        Group {
            let nodes = nodes
            if nodes.isEmpty {
                ContentUnavailableView(PalmiL10n.tr("workspace.files.emptyFolder"), systemImage: "folder")
            } else {
                List(nodes) { node in
                    if node.isDirectory {
                        NavigationLink {
                            SkillFolderScreen(rootURL: rootURL, relativePath: node.relativePath, title: node.name)
                        } label: {
                            WorkspaceFileRowLabel(node: node)
                        }
                    } else {
                        Button { preview(node) } label: { WorkspaceFileRowLabel(node: node) }
                            .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $previewedFile) { WorkspaceFilePreviewSheet(file: $0) }
        .alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private func preview(_ node: WorkspaceFileNode) {
        do {
            previewedFile = try WorkspacePreviewFileLoader.load(relativePath: node.relativePath) { rootURL.appendingPathComponent($0) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum SkillFileNodeBuilder {
    /// 文件夹在前，其余按名称排序；子节点只用于显示条目数。
    static func nodes(in directory: URL, root: URL) -> [WorkspaceFileNode] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .map { url -> WorkspaceFileNode in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return WorkspaceFileNode(
                    id: relative, name: url.lastPathComponent, relativePath: relative, url: url,
                    isDirectory: isDirectory, children: isDirectory ? nodes(in: url, root: root) : []
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
