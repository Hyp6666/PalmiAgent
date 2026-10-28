import Foundation
import ImageIO
import CoreGraphics

// CGImage is immutable after creation; the wrapper is safe across actor boundaries.
nonisolated struct PalmiAttachmentThumbnail: @unchecked Sendable {
    let cgImage: CGImage
    var cost: Int { cgImage.bytesPerRow * cgImage.height }
}

private nonisolated final class PalmiAttachmentThumbnailBox: NSObject {
    let value: PalmiAttachmentThumbnail
    init(_ value: PalmiAttachmentThumbnail) { self.value = value }
}

actor PalmiAttachmentThumbnailStore {
    static let shared = PalmiAttachmentThumbnailStore()
    private let cache = NSCache<NSString, PalmiAttachmentThumbnailBox>()
    private var flights: [String: Task<PalmiAttachmentThumbnail?, Never>] = [:]

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 80
    }

    func thumbnail(url: URL, maxPixel: Int) async -> PalmiAttachmentThumbnail? {
        guard url.isFileURL else { return nil }
        let pixel = min(4_096, max(64, maxPixel))
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.standardizedFileURL.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(pixel)"
        if let box = cache.object(forKey: key as NSString) { return box.value }
        if let flight = flights[key] { return await flight.value }
        let task = Task.detached(priority: .utility) {
            Self.decode(url: url, maxPixel: pixel)
        }
        flights[key] = task
        let value = await task.value
        flights[key] = nil
        if let value {
            cache.setObject(PalmiAttachmentThumbnailBox(value), forKey: key as NSString, cost: value.cost)
        }
        return value
    }

    nonisolated private static func decode(url: URL, maxPixel: Int) -> PalmiAttachmentThumbnail? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled else { return nil }
        return PalmiAttachmentThumbnail(cgImage: image)
    }
}
