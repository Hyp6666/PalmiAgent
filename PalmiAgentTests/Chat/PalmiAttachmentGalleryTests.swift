import XCTest
import SwiftUI
import UIKit
@testable import PalmiAgent

@MainActor
final class PalmiAttachmentGalleryTests: XCTestCase {
    func testFifteenImagesRemainScrollableWithinComposerHeightBudgets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...15 {
            let size = index % 3 == 0 ? CGSize(width: 400, height: 800) : CGSize(width: 800, height: 400)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(hue: CGFloat(index) / 15, saturation: 0.6, brightness: 0.85, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let text = "\(index)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 100), .foregroundColor: UIColor.white]
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
            }
            try XCTUnwrap(image.jpegData(compressionQuality: 0.85)).write(to: root.appendingPathComponent("\(index).jpg"))
        }
        let attachments = (1...15).map {
            PalmiChatAttachment(id: UUID(), name: "Photo \($0).jpg", relativePath: "\($0).jpg", source: .filePicker)
        }
        let configurations: [(String, Bool, UserInterfaceSizeClass, CGFloat)] = [
            ("portrait", false, .regular, 360),
            ("focused", true, .regular, 190),
            ("landscape", false, .compact, 148)
        ]
        for (name, focused, vertical, limit) in configurations {
            let gallery = PalmiAttachmentGallery(attachments: attachments, presentation: .composer,
                composerIsFocused: focused, resolvedURL: { root.appendingPathComponent($0.relativePath) }, onTap: { _ in }, onRemove: { _ in })
                .environment(\.verticalSizeClass, vertical)
                .environment(\.dynamicTypeSize, name == "landscape" ? .accessibility3 : .large)
                .preferredColorScheme(name == "focused" ? .dark : .light)
            let host = UIHostingController(rootView: VStack(spacing: 8) {
                gallery
                TextField("Message", text: .constant("Draft remains reachable"))
            }.frame(width: 360))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            let scroll = try XCTUnwrap(findScrollView(in: host.view), name)
            XCTAssertLessThanOrEqual(scroll.bounds.height, limit, name)
            // Fifteen images occupy five rows; all rows must remain in the scrollable content.
            XCTAssertGreaterThan(scroll.contentSize.height, 500, name)
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height, name)
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            // Lazy grid measurements can settle after the first scroll; use its final extent.
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertGreaterThan(scroll.contentOffset.y, 200, name)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "FifteenAttachments-\(name)-lastRow"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testThumbnailDownsamplesWithoutCroppingOrChangingOriginalFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let bytes = try XCTUnwrap(original.jpegData(compressionQuality: 0.9))
        let url = root.appendingPathComponent("wide.jpg")
        try bytes.write(to: url)
        let result = await PalmiAttachmentThumbnailStore.shared.thumbnail(url: url, maxPixel: 200)
        let thumbnail = try XCTUnwrap(result)
        XCTAssertEqual(thumbnail.cgImage.width, 200)
        XCTAssertEqual(thumbnail.cgImage.height, 100)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let damaged = root.appendingPathComponent("damaged.jpg")
        try Data("not an image".utf8).write(to: damaged)
        let failed = await PalmiAttachmentThumbnailStore.shared.thumbnail(url: damaged, maxPixel: 200)
        XCTAssertNil(failed)
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }
}
