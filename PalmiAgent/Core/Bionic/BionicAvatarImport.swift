import Foundation
import CoreGraphics
import ImageIO

nonisolated struct BionicAvatarCrop: Sendable {
    let centerX: Double
    let centerY: Double
    let size: Double
}

nonisolated struct BionicAvatarImportSpec: Sendable {
    let path: String
    let crop: BionicAvatarCrop?

    @MainActor
    static func parse(_ arguments: ToolArguments) throws -> Self? {
        let decoded = try JSONDecoder().decode(
            BionicJSON.self, from: Data(arguments.normalizedJSONString().utf8)
        )
        guard case .object(let object) = decoded else { throw BionicFailure("invalidFields") }
        guard let suppliedPath = object["avatar_path"] else {
            guard object["avatar_crop"] == nil else {
                throw BionicFailure("invalidFields", detail: "avatar_crop requires avatar_path")
            }
            return nil
        }
        guard case .string(let sourcePath) = suppliedPath else {
            throw BionicFailure("invalidFields", detail: "avatar_path")
        }
        let path = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"),
              !path.contains("\\"), !path.contains("\0") else {
            throw BionicFailure("invalidFields", detail: "avatar_path")
        }
        _ = try BionicCodec.safeRelativePath(path)
        var crop: BionicAvatarCrop?
        if let suppliedCrop = object["avatar_crop"] {
            guard case .object(let fields) = suppliedCrop,
                  Set(fields.keys) == Set(["center_x", "center_y", "size"]) else {
                throw BionicFailure("invalidFields", detail: "avatar_crop")
            }
            func number(_ key: String) throws -> Double {
                let value: Double
                switch fields[key] {
                case .number(let n): value = n
                case .integer(let n): value = Double(n)
                default: throw BionicFailure("invalidFields", detail: "avatar_crop." + key)
                }
                guard value.isFinite else { throw BionicFailure("invalidFields") }
                return value
            }
            let x = try number("center_x")
            let y = try number("center_y")
            let size = try number("size")
            guard (0...1).contains(x), (0...1).contains(y), size > 0, size <= 1 else {
                throw BionicFailure("invalidFields", detail: "avatar_crop")
            }
            crop = BionicAvatarCrop(centerX: x, centerY: y, size: size)
        }
        return Self(path: path, crop: crop)
    }
}

actor BionicAvatarImporter {
    static let shared = BionicAvatarImporter()
    private let maximumBytes = 20 * 1024 * 1024

    func prepare(url: URL, crop: BionicAvatarCrop?) throws -> Data {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let byteCount = values.fileSize, byteCount > 0, byteCount <= maximumBytes else {
            throw BionicFailure("invalidImage")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw BionicFailure("invalidImage")
        }
        let w = width.doubleValue
        let h = height.doubleValue
        guard w.isFinite, h.isFinite, w > 0, h > 0, w * h <= 100_000_000 else {
            throw BionicFailure("invalidImage")
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw BionicFailure("invalidImage") }
        try Task.checkCancellation()
        let shortSide = min(image.width, image.height)
        let side = max(1, min(shortSide, Int((Double(shortSide) * (crop?.size ?? 1)).rounded())))
        let centerX = (crop?.centerX ?? 0.5) * Double(image.width)
        let centerY = (crop?.centerY ?? 0.5) * Double(image.height)
        let x = max(0, min(image.width - side, Int((centerX - Double(side) / 2).rounded())))
        let y = max(0, min(image.height - side, Int((centerY - Double(side) / 2).rounded())))
        guard let square = image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(side), height: CGFloat(side))),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: 256, height: 256, bitsPerComponent: 8,
                bytesPerRow: 256 * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw BionicFailure("invalidImage") }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let outputImage = context.makeImage() else { throw BionicFailure("invalidImage") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil
        ) else { throw BionicFailure("invalidImage") }
        CGImageDestinationAddImage(destination, outputImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw BionicFailure("invalidImage") }
        try Task.checkCancellation()
        return output as Data
    }
}
