import SwiftUI
import QuickLook
import UIKit
import ImageIO

struct WorkspacePreviewFile: Identifiable {
    enum PreviewKind: Equatable {
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

enum WorkspaceLinkResolver {
    static func relativeWorkspacePath(from url: URL) -> String? {
        if url.scheme?.lowercased() == "palmi-workspace" {
            let path = url.path.isEmpty ? url.host ?? "" : url.path
            return normalizedRelativePath(path)
        }

        guard url.scheme == nil, url.host == nil else { return nil }
        return normalizedRelativePath(url.path)
    }

    private static func normalizedRelativePath(_ rawPath: String) -> String? {
        let components = rawPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }
}

enum WorkspacePreviewContentLoader {
    static func loadCompleteText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // Encoding detection only needs the prefix. Keep the complete mapped data for the
        // actual decode so viewing a large text file does not create a second full-size byte copy.
        let detected = try TextEncodingDetector.detect(sample: Data(data.prefix(64 * 1024)))
        let encodedContent = data.dropFirst(detected.bomLength)
        let encoding = TextEncodingDetector.stringEncoding(detected.encoding)
        guard let text = String(data: encodedContent, encoding: encoding) else {
            throw RawTextReadError.decodingFailed
        }
        return text
    }
}

enum WorkspacePreviewFileLoader {
    static func load(
        relativePath: String,
        resolveURL: (String) throws -> URL
    ) throws -> WorkspacePreviewFile {
        let trimmedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else {
            throw AppError.invalidState(PalmiL10n.tr("filePreview.fileNotFound"))
        }

        let url = try resolveURL(trimmedPath)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw AppError.invalidState(PalmiL10n.tr("filePreview.fileNotFound"))
        }

        let kind = WorkspacePreviewFile.previewKind(for: url)
        let preview: String?
        switch kind {
        case .markdown, .text:
            let content = try WorkspacePreviewContentLoader.loadCompleteText(at: url)
            preview = content.isEmpty ? PalmiL10n.tr("filePreview.emptyFile") : content
        case .quickLook:
            preview = nil
        }

        return WorkspacePreviewFile(
            title: url.lastPathComponent,
            relativePath: trimmedPath,
            url: url,
            preview: preview,
            kind: kind
        )
    }
}

struct WorkspaceFilePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: WorkspacePreviewFile

    var body: some View {
        NavigationStack {
            WorkspaceFilePreviewContent(file: file)
                .background(.white)
                .navigationTitle(file.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(PalmiL10n.tr("common.close")) {
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
}

struct WorkspaceFileCarouselPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let files: [WorkspacePreviewFile]
    let initialFileID: UUID
    @State private var selectedFileID: UUID

    init(files: [WorkspacePreviewFile], initialFileID: UUID) {
        self.files = files
        self.initialFileID = initialFileID
        _selectedFileID = State(initialValue: initialFileID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(PalmiL10n.tr("filePreview.noAttachments"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white)
                } else {
                    ZStack(alignment: .bottom) {
                        TabView(selection: $selectedFileID) {
                            ForEach(files) { file in
                                WorkspaceFilePreviewContent(file: file)
                                    .tag(file.id)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: files.count > 1 ? .automatic : .never))

                        if files.count > 1 {
                            carouselControls
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }
                    }
                    .background(.white)
                }
            }
            .navigationTitle(currentFile?.title ?? PalmiL10n.tr("filePreview.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(PalmiL10n.tr("common.close")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if let currentFile {
                        ShareLink(item: currentFile.url) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                goToNextFile()
            case .decrement:
                goToPreviousFile()
            @unknown default:
                break
            }
        }
    }

    private var currentFile: WorkspacePreviewFile? {
        files.first { $0.id == selectedFileID } ?? files.first
    }

    private var selectedIndex: Int {
        files.firstIndex { $0.id == selectedFileID } ?? 0
    }

    private var canGoPrevious: Bool {
        selectedIndex > 0
    }

    private var canGoNext: Bool {
        selectedIndex < files.count - 1
    }

    private var carouselControls: some View {
        HStack(spacing: 14) {
            Button(action: goToPreviousFile) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .disabled(!canGoPrevious)
            .accessibilityLabel(PalmiL10n.tr("filePreview.previousAttachment"))

            Text([String(selectedIndex + 1), String(files.count)].joined(separator: " / "))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 56)

            Button(action: goToNextFile) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .disabled(!canGoNext)
            .accessibilityLabel(PalmiL10n.tr("filePreview.nextAttachment"))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.58)))
    }

    private func goToPreviousFile() {
        let nextIndex = max(0, selectedIndex - 1)
        guard files.indices.contains(nextIndex) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedFileID = files[nextIndex].id
        }
    }

    private func goToNextFile() {
        let nextIndex = min(files.count - 1, selectedIndex + 1)
        guard files.indices.contains(nextIndex) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedFileID = files[nextIndex].id
        }
    }
}

private struct WorkspaceFilePreviewContent: View {
    let file: WorkspacePreviewFile

    var body: some View {
        switch file.kind {
        case .markdown:
            ScrollView {
                SelectableMarkdownTextView(markdown: file.preview ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

        case .text:
            ScrollView {
                SelectablePlainTextView(
                    text: file.preview ?? PalmiL10n.tr("filePreview.emptyFile"),
                    font: .monospacedSystemFont(
                        ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                        weight: .regular
                    )
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }

        case .quickLook:
            if WorkspaceImagePreview.isSupported(url: file.url) {
                WorkspaceImagePreview(url: file.url)
            } else {
                QuickLookPreview(url: file.url)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }
}

private struct WorkspaceImagePreview: View {
    let url: URL
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.96)
                .ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else if didFail {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.system(size: 32, weight: .semibold))
                    Text(PalmiL10n.tr("filePreview.emptyImage"))
                        .font(.headline)
                }
                .foregroundStyle(.white.opacity(0.82))
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    static func isSupported(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff"].contains(ext)
    }

    private func loadImage() async {
        let loadedImage = await Task.detached(priority: .utility) {
            Self.downsample(url: url, maxPixel: 2_400)
        }.value

        await MainActor.run {
            image = loadedImage
            didFail = loadedImage == nil
        }
    }

    nonisolated private static func downsample(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
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
        guard context.coordinator.replaceURLIfNeeded(url) else { return }
        uiViewController.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        @discardableResult
        func replaceURLIfNeeded(_ newURL: URL) -> Bool {
            guard url != newURL else { return false }
            url = newURL
            return true
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
