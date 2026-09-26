import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

actor BionicBackgroundImageProcessor {
    static let shared = BionicBackgroundImageProcessor()

    func prepare(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0, width * height <= 200_000_000 else {
            throw BionicFailure("invalidImage")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw BionicFailure("invalidImage")
        }
        return try jpeg(image)
    }

    func crop(_ data: Data, normalizedRect: CGRect) throws -> Data {
        let r = normalizedRect
        guard [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite),
              r.width > 0, r.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BionicFailure("invalidImage")
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixels = CGRect(x: r.minX * bounds.width, y: r.minY * bounds.height,
                            width: r.width * bounds.width, height: r.height * bounds.height)
            .integral.intersection(bounds)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1,
              let cropped = image.cropping(to: pixels) else { throw BionicFailure("invalidImage") }
        return try jpeg(cropped)
    }

    private func jpeg(_ image: CGImage) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw BionicFailure("invalidImage")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let flattened = context.makeImage() else { throw BionicFailure("invalidImage") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw BionicFailure("invalidImage") }
        CGImageDestinationAddImage(destination, flattened, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BionicFailure("invalidImage") }
        return output as Data
    }
}
