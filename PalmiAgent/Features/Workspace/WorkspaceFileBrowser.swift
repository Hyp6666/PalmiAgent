import SwiftUI
import UIKit

/// 文件夹层级路由。由外层 NavigationStack 统一注册，文件夹页本身不再嵌套导航栈。
struct WorkspaceFolderRoute: Hashable {
    let relativePath: String
}

/// 「所有项目文件」入口里的项目路由。
private struct WorkspaceProjectFilesRoute: Hashable {
    let projectID: UUID
}

/// 当前会话 / 正在浏览项目的文件浏览器（iPad 分栏内容列直接嵌入）。
struct WorkspaceBrowser: View {
    @Bindable var store: WorkspaceStore
    var onClose: (() -> Void)? = nil
    @State private var path: [WorkspaceFolderRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            WorkspaceFolderScreen(store: store, relativePath: nil, onClose: onClose)
                .navigationDestination(for: WorkspaceFolderRoute.self) { route in
                    WorkspaceFolderScreen(store: store, relativePath: route.relativePath)
                }
        }
        .workspaceShareSheet(store)
        .task { store.refreshCurrentThreadContents() }
        // 换了项目或会话，旧的子文件夹路径不再属于当前工作区。
        .onChange(of: store.browsedProjectID) { _, _ in path = [] }
        .onChange(of: store.selectedProjectID) { _, _ in path = [] }
    }
}

struct WorkspaceBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: WorkspaceStore

    var body: some View {
        WorkspaceBrowser(store: store, onClose: { dismiss() })
    }
}

/// 专业模式「文件」入口：列出全部项目工作区，点进去与会话内看文件夹是同一套界面。
struct WorkspaceAllProjectsFilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: WorkspaceStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.projects.isEmpty {
                    ContentUnavailableView(PalmiL10n.tr("workspace.files.noProjects"), systemImage: "folder")
                } else {
                    // 默认工作区单独一组，自建工作区在下面另一组。
                    List {
                        if let defaultWorkspace = store.defaultWorkspace {
                            Section { projectRow(defaultWorkspace) }
                        }
                        if !store.workspaceProjects.isEmpty {
                            Section { ForEach(store.workspaceProjects) { projectRow($0) } }
                        }
                    }
                }
            }
            .navigationTitle(PalmiL10n.tr("workspace.files.allProjects"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(PalmiL10n.tr("common.close")) { dismiss() }
                }
            }
            .navigationDestination(for: WorkspaceProjectFilesRoute.self) { route in
                WorkspaceFolderScreen(store: store, relativePath: nil, projectID: route.projectID)
            }
            .navigationDestination(for: WorkspaceFolderRoute.self) { route in
                WorkspaceFolderScreen(store: store, relativePath: route.relativePath)
            }
        }
        .workspaceShareSheet(store)
    }

    private func projectRow(_ project: WorkspaceProjectRecord) -> some View {
        NavigationLink(value: WorkspaceProjectFilesRoute(projectID: project.id)) {
            HStack(spacing: 12) {
                PalmiFileIcon(name: project.name, isDirectory: true, size: 30)
                    .frame(width: 30)
                Text(project.name).lineLimit(1)
            }
            .padding(.vertical, 4)
        }
    }
}

/// 一个文件夹的内容。relativePath 为 nil 表示工作区根目录。
struct WorkspaceFolderScreen: View {
    @Bindable var store: WorkspaceStore
    let relativePath: String?
    /// 非 nil 时，此页是某个项目的根目录：出现时把浏览作用域锁定到该项目。
    var projectID: UUID? = nil
    var onClose: (() -> Void)? = nil

    @State private var previewedFile: WorkspacePreviewFile?
    @State private var attachmentPresentation: PalmiAttachmentImportPresentation?
    @State private var isCreatingFolder = false
    @State private var nameDraft = ""
    @State private var renamingNode: WorkspaceFileNode?
    @State private var deletingNode: WorkspaceFileNode?

    private var basePath: String { relativePath ?? "" }

    private var nodes: [WorkspaceFileNode] {
        guard let relativePath else { return store.fileTree }
        return Self.findNode(at: relativePath, in: store.fileTree)?.children ?? []
    }

    private var title: String {
        if let relativePath { return (relativePath as NSString).lastPathComponent }
        if let projectID, let project = store.projects.first(where: { $0.id == projectID }) { return project.name }
        return PalmiL10n.tr("workspace.files.title")
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { statusBanner }
            .refreshable { store.refreshCurrentThreadContents() }
            .onAppear(perform: lockProjectScopeIfNeeded)
            .sheet(item: $previewedFile) { file in
                WorkspaceFilePreviewSheet(file: file)
            }
            .palmiAttachmentImporter(
                presentation: $attachmentPresentation,
                workspaceStore: store,
                onComplete: { _ in },
                onError: { store.statusMessage = $0 }
            )
            .alert(PalmiL10n.tr("workspace.folder.new"), isPresented: $isCreatingFolder) {
                TextField(PalmiL10n.tr("workspace.folder.name"), text: $nameDraft)
                    .textInputAutocapitalization(.never)
                Button(PalmiL10n.tr("common.cancel"), role: .cancel) { }
                Button(PalmiL10n.tr("common.create")) { createFolder() }
            }
            .alert(PalmiL10n.tr("common.rename"), isPresented: Binding(
                get: { renamingNode != nil },
                set: { if !$0 { renamingNode = nil } }
            )) {
                TextField(PalmiL10n.tr("workspace.file.newName"), text: $nameDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(PalmiL10n.tr("common.cancel"), role: .cancel) { renamingNode = nil }
                Button(PalmiL10n.tr("common.save")) {
                    if let node = renamingNode { store.renameNode(node, to: nameDraft) }
                    renamingNode = nil
                }
            }
            .confirmationDialog(
                PalmiL10n.tr("workspace.file.deleteConfirm.title", deletingNode?.name ?? ""),
                isPresented: Binding(
                    get: { deletingNode != nil },
                    set: { if !$0 { deletingNode = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(PalmiL10n.tr("common.delete"), role: .destructive) {
                    if let node = deletingNode { store.deleteNode(node) }
                    deletingNode = nil
                }
                Button(PalmiL10n.tr("common.cancel"), role: .cancel) { deletingNode = nil }
            } message: {
                Text(PalmiL10n.tr(deletingNode?.isDirectory == true
                    ? "workspace.file.deleteConfirm.folderMessage"
                    : "workspace.file.deleteConfirm.message"))
            }
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasBrowsableWorkspace {
            ContentUnavailableView(PalmiL10n.tr("workspace.empty.selectSession"), systemImage: "tray")
        } else if nodes.isEmpty {
            ContentUnavailableView(PalmiL10n.tr("workspace.files.emptyFolder"), systemImage: "folder")
        } else {
            List {
                ForEach(nodes) { node in
                    row(node)
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func row(_ node: WorkspaceFileNode) -> some View {
        if node.isDirectory {
            // 子文件夹由外层导航栈注册的 WorkspaceFolderRoute 目的地处理。
            NavigationLink(value: WorkspaceFolderRoute(relativePath: node.relativePath)) {
                WorkspaceFileRowLabel(node: node)
            }
            .modifier(rowActions(node))
        } else {
            Button { preview(node) } label: {
                WorkspaceFileRowLabel(node: node)
            }
            .buttonStyle(.plain)
            .modifier(rowActions(node))
        }
    }

    private func rowActions(_ node: WorkspaceFileNode) -> WorkspaceFileRowActions {
        WorkspaceFileRowActions(node: node, onRename: beginRename, onShare: store.exportNode,
                                onDelete: { deletingNode = $0 })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .topBarLeading) {
                Button(PalmiL10n.tr("common.close"), action: onClose)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button { beginCreateFolder() } label: {
                    Label(PalmiL10n.tr("workspace.folder.new"), systemImage: "folder.badge.plus")
                }
                Divider()
                Button { importAttachments(PalmiAttachmentActions.camera(destination: .directory(relativePath: basePath))) } label: {
                    Label(PalmiL10n.tr("attachment.camera"), systemImage: "camera")
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button { importAttachments(PalmiAttachmentActions.photos(destination: .directory(relativePath: basePath))) } label: {
                    Label(PalmiL10n.tr("attachment.photos"), systemImage: "photo")
                }
                Button { importAttachments(PalmiAttachmentActions.files(destination: .directory(relativePath: basePath))) } label: {
                    Label(PalmiL10n.tr("attachment.files"), systemImage: "doc")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(PalmiL10n.tr("workspace.file.add"))
            .disabled(!store.hasBrowsableWorkspace)

            Menu {
                Button { store.refreshCurrentThreadContents() } label: {
                    Label(PalmiL10n.tr("common.refresh"), systemImage: "arrow.clockwise")
                }
                Button { store.toggleHiddenFilesVisibility() } label: {
                    Label(
                        PalmiL10n.tr(store.showsHiddenFiles ? "workspace.file.hideHidden" : "workspace.file.showHidden"),
                        systemImage: store.showsHiddenFiles ? "eye.slash" : "eye"
                    )
                }
                Button { store.exportCurrentThread() } label: {
                    Label(PalmiL10n.tr("workspace.file.exportProject"), systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(PalmiL10n.tr("workspace.files.more"))
            .disabled(!store.hasBrowsableWorkspace)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = store.statusMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
        }
    }

    private func lockProjectScopeIfNeeded() {
        guard let projectID, store.browsedProjectID != projectID else { return }
        store.browsedProjectID = projectID
        store.refreshCurrentThreadContents()
    }

    private func preview(_ node: WorkspaceFileNode) {
        do {
            previewedFile = try WorkspacePreviewFileLoader.load(
                relativePath: node.relativePath,
                resolveURL: store.workspaceURL(for:)
            )
            store.statusMessage = nil
        } catch {
            store.statusMessage = error.localizedDescription
        }
    }

    private func beginCreateFolder() {
        nameDraft = ""
        isCreatingFolder = true
    }

    private func beginRename(_ node: WorkspaceFileNode) {
        nameDraft = node.name
        renamingNode = node
    }

    private func createFolder() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.createFolder(at: basePath.isEmpty ? name : basePath + "/" + name)
    }

    private func importAttachments(_ presentation: PalmiAttachmentImportPresentation) {
        attachmentPresentation = presentation
    }

    static func findNode(at relativePath: String, in nodes: [WorkspaceFileNode]) -> WorkspaceFileNode? {
        for node in nodes {
            if node.relativePath == relativePath { return node }
            // 只沿路径前缀向下找，不遍历无关分支。
            if node.isDirectory, relativePath.hasPrefix(node.relativePath + "/"),
               let child = findNode(at: relativePath, in: node.children) {
                return child
            }
        }
        return nil
    }
}

struct WorkspaceFileRowLabel: View {
    let node: WorkspaceFileNode

    var body: some View {
        HStack(spacing: 12) {
            PalmiFileIcon(name: node.name, isDirectory: node.isDirectory, size: 34)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if node.isDirectory { return PalmiL10n.tr("workspace.files.itemCount", node.children.count) }
        let size = (try? node.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }


}

// MARK: - 行操作与分享

private struct WorkspaceFileRowActions: ViewModifier {
    let node: WorkspaceFileNode
    let onRename: (WorkspaceFileNode) -> Void
    let onShare: (WorkspaceFileNode) -> Void
    let onDelete: (WorkspaceFileNode) -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { onDelete(node) } label: {
                    Label(PalmiL10n.tr("common.delete"), systemImage: "trash")
                }
                Button { onShare(node) } label: {
                    Label(PalmiL10n.tr("common.share"), systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }
            .contextMenu {
                Button { onRename(node) } label: {
                    Label(PalmiL10n.tr("common.rename"), systemImage: "pencil")
                }
                Button { onShare(node) } label: {
                    Label(PalmiL10n.tr("common.share"), systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) { onDelete(node) } label: {
                    Label(PalmiL10n.tr("common.delete"), systemImage: "trash")
                }
            }
    }
}

private extension View {
    /// 分享面板只在导航栈外挂一次，避免每个文件夹页都绑定同一个 sharePayload。
    func workspaceShareSheet(_ store: WorkspaceStore) -> some View {
        modifier(WorkspaceShareSheetModifier(store: store))
    }
}

private struct WorkspaceShareSheetModifier: ViewModifier {
    @Bindable var store: WorkspaceStore

    func body(content: Content) -> some View {
        content.sheet(item: $store.sharePayload) { payload in
            ShareSheet(items: [payload.url])
        }
    }
}
