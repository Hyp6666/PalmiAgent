import UIKit

/// Disposable previews only. Never stores cookies or replaces a live page with a screenshot.
@MainActor
final class BrowserPreviewStore {
    private let cache = NSCache<NSString, UIImage>()
    private let directory: URL
    private let io = DispatchQueue(label: "palmi.browser.previews", qos: .utility)

    init(directory: URL = URL.cachesDirectory.appending(path: "BrowserPreviews", directoryHint: .isDirectory)) {
        self.directory = directory
        cache.totalCostLimit = 8 * 1_024 * 1_024
        cache.countLimit = 24
    }

    func image(for id: String) -> UIImage? { cache.object(forKey: id as NSString) }

    func load(_ id: String, completion: @escaping (UIImage?) -> Void) {
        if let image = image(for: id) { completion(image); return }
        let url = fileURL(id)
        io.async { [weak self] in
            let data = try? Data(contentsOf: url)
            Task { @MainActor [weak self] in
                let image = data.flatMap(UIImage.init(data:))
                if let image { self?.cache.setObject(image, forKey: id as NSString, cost: 240 * 320 * 4) }
                completion(image)
            }
        }
    }

    func save(_ image: UIImage, for id: String) {
        cache.setObject(image, forKey: id as NSString, cost: 240 * 320 * 4)
        let url = fileURL(id), directory = directory
        // A bounded 240×320 JPEG, written off the UI thread. Cache files are never backed up.
        io.async {
            guard let data = image.jpegData(compressionQuality: 0.75) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            let entries = files.compactMap { file -> (URL, Date, Int)? in
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
                return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }.sorted { $0.1 > $1.1 }
            var size = 0
            for (index, entry) in entries.enumerated() {
                size += entry.2
                if index >= 100 || size > 20 * 1_024 * 1_024 { try? FileManager.default.removeItem(at: entry.0) }
            }
        }
    }

    func remove(_ id: String) {
        cache.removeObject(forKey: id as NSString)
        let url = fileURL(id)
        io.async { try? FileManager.default.removeItem(at: url) }
    }

    func clearMemory() { cache.removeAllObjects() }

    private func fileURL(_ id: String) -> URL {
        // Records are persisted locally, but never treat an identifier as a filesystem path.
        let name = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(name + ".jpg")
    }
}
