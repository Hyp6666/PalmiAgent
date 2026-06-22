import Photos
import SwiftUI
import UIKit
import VisionKit

struct GeneratedPhotoInfo: Sendable {
    let size: CGSize
}

@MainActor
final class PhotoLibraryService {
    func saveGeneratedCard(
        title: String,
        subtitle: String?,
        body: String?,
        size: CGSize = CGSize(width: 1200, height: 900),
        topColorHex: String?,
        middleColorHex: String?,
        bottomColorHex: String?
    ) async throws -> GeneratedPhotoInfo {
        let addOnly = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        guard addOnly == .authorized || addOnly == .limited else {
            throw AppError.permissionDenied("照片写入权限没有授予。")
        }

        let canvasSize = CGSize(width: max(600, size.width), height: max(400, size.height))
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        let image = renderer.image { ctx in
            let colors = [
                UIColor(hex: topColorHex) ?? .systemTeal,
                UIColor(hex: middleColorHex) ?? .systemBlue,
                UIColor(hex: bottomColorHex) ?? .black
            ].map(\.cgColor) as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.55, 1])!
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: canvasSize.width, y: canvasSize.height),
                options: []
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left

            let title = NSAttributedString(
                string: title,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 96, weight: .bold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph
                ]
            )
            let subtitle = NSAttributedString(
                string: subtitle ?? "",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 42, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                    .paragraphStyle: paragraph
                ]
            )
            let bodyText = NSAttributedString(
                string: body ?? "",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.88),
                    .paragraphStyle: paragraph
                ]
            )
            title.draw(in: CGRect(x: 72, y: 120, width: canvasSize.width - 144, height: 140))
            subtitle.draw(in: CGRect(x: 72, y: 280, width: canvasSize.width - 144, height: 100))
            bodyText.draw(in: CGRect(x: 72, y: 390, width: canvasSize.width - 144, height: canvasSize.height - 460))
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: AppError.operationFailed("照片写入失败。"))
                }
            }
        }

        return GeneratedPhotoInfo(size: image.size)
    }
}

private extension UIColor {
    convenience init?(hex: String?) {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6, let value = Int(hex, radix: 16) else {
            return nil
        }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}

enum MediaPresentation: @unchecked Sendable, Identifiable {
    case imagePicker(ToolActionID, UIImagePickerController.SourceType)
    case documentScanner(ToolActionID)
    case textScanner(ToolActionID)
    case safari(ToolActionID, SafariPresentationOptions)

    var id: String {
        switch self {
        case .imagePicker(let actionID, let source):
            "\(actionID.rawValue).picker.\(source.rawValue)"
        case .documentScanner(let actionID):
            "\(actionID.rawValue).document-scanner"
        case .textScanner(let actionID):
            "\(actionID.rawValue).text-scanner"
        case .safari(let actionID, let options):
            "\(actionID.rawValue).safari.\(options.url.absoluteString).title-\(options.displayTitle ?? "none").reader-\(options.entersReaderIfAvailable).collapse-\(options.barCollapsingEnabled).read-\(options.fileReadAccessURL?.absoluteString ?? "none")"
        }
    }

    var actionID: ToolActionID {
        switch self {
        case .imagePicker(let actionID, _),
             .documentScanner(let actionID),
             .textScanner(let actionID),
             .safari(let actionID, _):
            actionID
        }
    }

    var sourceType: UIImagePickerController.SourceType? {
        switch self {
        case .imagePicker(_, let source):
            source
        case .documentScanner(_), .textScanner(_), .safari(_, _):
            nil
        }
    }

    var safariURL: URL? {
        switch self {
        case .safari(_, let options):
            options.url
        case .imagePicker(_, _), .documentScanner(_), .textScanner(_):
            nil
        }
    }

    var safariOptions: SafariPresentationOptions? {
        switch self {
        case .safari(_, let options):
            options
        case .imagePicker(_, _), .documentScanner(_), .textScanner(_):
            nil
        }
    }
}

struct SafariPresentationOptions: Hashable, Sendable {
    let url: URL
    let fileReadAccessURL: URL?
    let displayTitle: String?
    let entersReaderIfAvailable: Bool
    let barCollapsingEnabled: Bool
}

struct ImagePickerBridge: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onFinish: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.delegate = context.coordinator
        controller.sourceType = sourceType
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
        ) {
            let image = info[.originalImage] as? UIImage
            onFinish(image)
        }
    }
}

struct DocumentScannerBridge: UIViewControllerRepresentable {
    let onFinish: (Int?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: (Int?) -> Void

        init(onFinish: @escaping (Int?) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
            onFinish(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish(scan.pageCount)
        }
    }
}

struct LiveTextScannerBridge: UIViewControllerRepresentable {
    let onFinish: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFinish: (String?) -> Void

        init(onFinish: @escaping (String?) -> Void) {
            self.onFinish = onFinish
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            if let first = addedItems.first,
               case .text(let text) = first {
                onFinish(text.transcript)
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onFinish(nil)
        }
    }
}
