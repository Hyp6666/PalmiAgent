import SwiftUI
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PalmiMarkdownImageReference: Equatable, Sendable {
    let alt: String
    let source: String
}
nonisolated enum PalmiMarkdownImageParser {
    enum Piece { case text(String), image(PalmiMarkdownImageReference) }
    static func split(_ text: String) -> [Piece] {
        let a = Array(text)
        var output: [Piece] = [], start = 0, i = 0, ticks = 0
        while i < a.count {
            if a[i] == "\\" { i += min(2, a.count - i); continue }
            if a[i] == "`" {
                var end = i; while end < a.count && a[end] == "`" { end += 1 }
                let count = end - i
                if ticks == 0 { ticks = count } else if ticks == count { ticks = 0 }
                i = end; continue
            }
            guard ticks == 0, a[i] == "!", i + 1 < a.count, a[i+1] == "[" else { i += 1; continue }
            let begin = i
            var j = i + 2
            while j < a.count && a[j] != "]" && a[j] != "\n" {
                j += a[j] == "\\" && j + 1 < a.count ? 2 : 1
            }
            guard j + 1 < a.count, a[j] == "]", a[j+1] == "(" else { i += 1; continue }
            let alt = String(a[(i+2)..<j]); j += 2
            while j < a.count && (a[j] == " " || a[j] == "\t") { j += 1 }
            let angle = j < a.count && a[j] == "<"
            if angle { j += 1 }
            let target = j
            var depth = 0
            while j < a.count {
                if a[j] == "\\", j + 1 < a.count { j += 2; continue }
                if angle && a[j] == ">" { break }
                if !angle {
                    if a[j] == "(" { depth += 1 }
                    if a[j] == ")" { if depth == 0 { break }; depth -= 1 }
                    if a[j].isWhitespace && depth == 0 { break }
                }
                if a[j] == "\n" { break }
                j += 1
            }
            guard j > target else { i += 1; continue }
            let source = String(a[target..<j])
            if angle {
                guard j < a.count && a[j] == ">" else { i += 1; continue }
                j += 1
            }
            while j < a.count && (a[j] == " " || a[j] == "\t") { j += 1 }
            if j < a.count && (a[j] == "\"" || a[j] == "'") {
                let quote = a[j]; j += 1
                while j < a.count && a[j] != quote && a[j] != "\n" { j += a[j] == "\\" && j+1 < a.count ? 2 : 1 }
                guard j < a.count && a[j] == quote else { i += 1; continue }
                j += 1
                while j < a.count && (a[j] == " " || a[j] == "\t") { j += 1 }
            }
            guard j < a.count && a[j] == ")" else { i += 1; continue }
            if begin > start { output.append(.text(String(a[start..<begin]))) }
            output.append(.image(.init(alt: alt, source: source
                .replacingOccurrences(of: "\\(", with: "(").replacingOccurrences(of: "\\)", with: ")")
                .replacingOccurrences(of: "\\ ", with: " "))))
            i = j + 1; start = i
        }
        if start < a.count { output.append(.text(String(a[start...]))) }
        return output
    }
}
private struct PalmiImageRootKey: EnvironmentKey { static let defaultValue: URL? = nil }
private struct PalmiImagePreviewKey: EnvironmentKey { static let defaultValue: (Bool) -> Void = { _ in } }
extension EnvironmentValues {
    var palmiImageRoot: URL? {
        get { self[PalmiImageRootKey.self] }
        set { self[PalmiImageRootKey.self] = newValue }
    }
    var palmiImagePreviewChanged: (Bool) -> Void {
        get { self[PalmiImagePreviewKey.self] }
        set { self[PalmiImagePreviewKey.self] = newValue }
    }
}
nonisolated struct PalmiLoadedMarkdownImage: Sendable { let thumbnail: Data; let file: URL }
actor PalmiMarkdownImageLoader {
    static let shared = PalmiMarkdownImageLoader()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()
    private var cache: [String: PalmiLoadedMarkdownImage] = [:]
    func load(_ sourceText: String, root: URL?) async throws -> PalmiLoadedMarkdownImage {
        let remote = URL(string: sourceText).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        var key = (root?.path ?? "") + "\u{0}" + sourceText
        var local: URL?
        if remote == nil {
            let path = sourceText.removingPercentEncoding ?? sourceText
            guard let root, !path.hasPrefix("/"), !path.contains("\u{0}"), URL(string: path)?.scheme == nil else { throw BionicFailure("invalidImage") }
            let base = root.standardizedFileURL.resolvingSymlinksInPath()
            let target = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard target.pathComponents.starts(with: base.pathComponents), target.pathComponents.count > base.pathComponents.count else { throw BionicFailure("invalidImage") }
            let info = try target.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard info.isRegularFile == true, (info.fileSize ?? 0) > 0, (info.fileSize ?? .max) <= 32 * 1024 * 1024 else { throw BionicFailure("invalidImage") }
            key += ":\(info.fileSize ?? 0):\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            local = target
        }
        if let value = cache[key], FileManager.default.fileExists(atPath: value.file.path) { return value }
        let data: Data, file: URL
        if let remote {
            guard remote.user == nil, remote.password == nil else { throw BionicFailure("invalidImage") }
            let (temporary, response) = try await session.download(from: remote)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let count = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  count > 0, count <= 32 * 1024 * 1024 else { throw BionicFailure("invalidImage") }
            data = try Data(contentsOf: temporary)
            guard let image = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(image),
                  let ext = UTType(type as String)?.preferredFilenameExtension else { throw BionicFailure("invalidImage") }
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MarkdownImages", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            file = folder.appendingPathComponent(BionicCodec.sha(data)).appendingPathExtension(ext)
            try data.write(to: file, options: .atomic)
        } else if let local { data = try Data(contentsOf: local); file = local }
        else { throw BionicFailure("invalidImage") }
        try Task.checkCancellation()
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw BionicFailure("invalidImage") }
        let bytes = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw BionicFailure("invalidImage") }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw BionicFailure("invalidImage") }
        let result = PalmiLoadedMarkdownImage(thumbnail: bytes as Data, file: file)
        if cache.count >= 12 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }
}
struct PalmiMarkdownImageView: View {
    let reference: PalmiMarkdownImageReference
    @Environment(\.palmiImageRoot) private var root
    @Environment(\.palmiImagePreviewChanged) private var previewChanged
    @State private var value: PalmiLoadedMarkdownImage?
    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var retry = UUID()
    @State private var preview: BionicAssetPreview?
    private var key: String { (root?.path ?? "") + "\u{0}" + reference.source + retry.uuidString }
    var body: some View {
        Group {
            if let image, let value {
                Button { preview = BionicAssetPreview(url: value.file) } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            } else if loadFailed {
                Button { retry = UUID() } label: { Label(PalmiL10n.tr("image.reload"), systemImage: "arrow.clockwise").frame(minHeight: 96) }
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 160) }
        }
        .accessibilityLabel(reference.alt.isEmpty ? PalmiL10n.tr("image.title") : reference.alt)
        .task(id: key) {
            let captured = key
            value = nil; image = nil; loadFailed = false
            do {
                let loaded = try await PalmiMarkdownImageLoader.shared.load(reference.source, root: root)
                guard !Task.isCancelled, captured == key else { return }
                value = loaded; image = UIImage(data: loaded.thumbnail)
            } catch { if !Task.isCancelled { loadFailed = true } }
        }
        .sheet(item: $preview) { BionicAssetPreviewSheet(url: $0.url) }
        .onChange(of: preview != nil) { _, active in previewChanged(active) }
        .onDisappear { previewChanged(false) }
    }
}
