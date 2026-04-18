import SwiftUI
import MarkdownUI
import QuickLook

struct WorkspacePreviewFile: Identifiable {
    enum PreviewKind {
        case markdown
        case text
        case quickLook
    }

    let id = UUID()
    let title: String
    let relativePath: String
    let url: URL
    let preview: String?
    let kind: PreviewKind

    static func previewKind(for url: URL) -> PreviewKind {
        let ext = url.pathExtension.lowercased()

        let markdownExtensions: Set<String> = ["md", "markdown"]
        if markdownExtensions.contains(ext) {
            return .markdown
        }

        let plainTextExtensions: Set<String> = [
            "txt", "text", "log", "json", "jsonl", "csv", "tsv",
            "html", "htm", "xml", "yaml", "yml", "toml", "ini", "cfg",
            "py", "js", "ts", "tsx", "jsx", "swift", "java", "kt", "rb",
            "go", "rs", "c", "cc", "cpp", "h", "hpp", "m", "mm", "sh",
            "zsh", "bash", "sql"
        ]
        if plainTextExtensions.contains(ext) {
            return .text
        }

        return .quickLook
    }
}

struct WorkspaceFilePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: WorkspacePreviewFile

    var body: some View {
        NavigationStack {
            previewBody
                .background(.white)
                .navigationTitle(file.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") {
                            dismiss()
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: file.url) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var previewBody: some View {
        switch file.kind {
        case .markdown:
            ScrollView {
                Markdown(file.preview ?? "")
                    .markdownTheme(.basic)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

        case .text:
            ScrollView {
                Text(file.preview ?? "该文件暂无可预览内容。")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

        case .quickLook:
            QuickLookPreview(url: file.url)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
