import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum PalmiAttachmentDestination: Hashable {
    case hiddenFilesBatch
    case directory(relativePath: String)
}

struct PalmiAttachmentImportConfiguration: Hashable {
    let destination: PalmiAttachmentDestination
    let allowsMultipleSelection: Bool
}

struct PalmiAttachmentImportPresentation: Identifiable, Hashable {
    let id = UUID()
    let source: WorkspaceAttachmentSource
    let configuration: PalmiAttachmentImportConfiguration
}

enum PalmiAttachmentActions {
    static func camera(
        destination: PalmiAttachmentDestination,
        allowsMultipleSelection: Bool = false
    ) -> PalmiAttachmentImportPresentation {
        PalmiAttachmentImportPresentation(
            source: .camera,
            configuration: PalmiAttachmentImportConfiguration(
                destination: destination,
                allowsMultipleSelection: allowsMultipleSelection
            )
        )
    }

    static func photos(
        destination: PalmiAttachmentDestination,
        allowsMultipleSelection: Bool = true
    ) -> PalmiAttachmentImportPresentation {
        PalmiAttachmentImportPresentation(
            source: .photoLibrary,
            configuration: PalmiAttachmentImportConfiguration(
                destination: destination,
                allowsMultipleSelection: allowsMultipleSelection
            )
        )
    }

    static func files(
        destination: PalmiAttachmentDestination,
        allowsMultipleSelection: Bool = true
    ) -> PalmiAttachmentImportPresentation {
        PalmiAttachmentImportPresentation(
            source: .filePicker,
            configuration: PalmiAttachmentImportConfiguration(
                destination: destination,
                allowsMultipleSelection: allowsMultipleSelection
            )
        )
    }
}

enum PalmiAttachmentImportCompletion {
    case hiddenFilesBatch(WorkspaceAttachmentBatch)
    case directory([WorkspaceStoredAttachment])
}

@MainActor
struct PalmiAttachmentImportHost: ViewModifier {
    @Binding var presentation: PalmiAttachmentImportPresentation?
    let workspaceStore: WorkspaceStore
    let onComplete: (PalmiAttachmentImportCompletion) -> Void
    let onError: (String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentation) { presentation in
                sheetContent(for: presentation)
            }
    }

    @ViewBuilder
    private func sheetContent(for presentation: PalmiAttachmentImportPresentation) -> some View {
        switch presentation.source {
        case .camera:
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                PalmiCameraPicker { item in
                    finish(item.map { [$0] } ?? [], configuration: presentation.configuration)
                }
            } else {
                PalmiAttachmentUnavailableSheet(message: "当前设备不可用相机。") {
                    self.presentation = nil
                }
            }
        case .photoLibrary:
            PalmiPhotoPicker(
                allowsMultipleSelection: presentation.configuration.allowsMultipleSelection
            ) { items in
                finish(items, configuration: presentation.configuration)
            }
        case .filePicker:
            PalmiDocumentPicker(
                allowsMultipleSelection: presentation.configuration.allowsMultipleSelection
            ) { items in
                finish(items, configuration: presentation.configuration)
            }
        }
    }

    private func finish(
        _ importedItems: [WorkspaceImportedAttachment],
        configuration: PalmiAttachmentImportConfiguration
    ) {
        presentation = nil
        guard !importedItems.isEmpty else { return }

        do {
            switch configuration.destination {
            case .hiddenFilesBatch:
                let batch = try workspaceStore.importAttachmentsToHiddenFiles(importedItems)
                onComplete(.hiddenFilesBatch(batch))
            case .directory(let relativePath):
                let limitedItems = Array(importedItems.prefix(1))
                let stored = try workspaceStore.importAttachments(limitedItems, toDirectory: relativePath)
                onComplete(.directory(stored))
            }
        } catch {
            onError((error as? AppError)?.localizedDescription ?? error.localizedDescription)
        }
    }
}

extension View {
    func palmiAttachmentImporter(
        presentation: Binding<PalmiAttachmentImportPresentation?>,
        workspaceStore: WorkspaceStore,
        onComplete: @escaping (PalmiAttachmentImportCompletion) -> Void,
        onError: @escaping (String) -> Void
    ) -> some View {
        modifier(
            PalmiAttachmentImportHost(
                presentation: presentation,
                workspaceStore: workspaceStore,
                onComplete: onComplete,
                onError: onError
            )
        )
    }
}

struct PalmiAttachmentMenu: View {
    let showsPlanningRows: Bool
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onFiles: () -> Void
    let onPlan: () -> Void
    let onGoal: () -> Void
    let onResearch: () -> Void

    init(
        showsPlanningRows: Bool,
        onCamera: @escaping () -> Void,
        onPhotos: @escaping () -> Void,
        onFiles: @escaping () -> Void,
        onPlan: @escaping () -> Void = {},
        onGoal: @escaping () -> Void = {},
        onResearch: @escaping () -> Void = {}
    ) {
        self.showsPlanningRows = showsPlanningRows
        self.onCamera = onCamera
        self.onPhotos = onPhotos
        self.onFiles = onFiles
        self.onPlan = onPlan
        self.onGoal = onGoal
        self.onResearch = onResearch
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                topButton(title: "相机", systemImage: "camera.fill", action: onCamera)
                topButton(title: "照片", systemImage: "photo.on.rectangle.angled", action: onPhotos)
                topButton(title: "文件", systemImage: "doc.fill", action: onFiles)
            }

            if showsPlanningRows {
                menuRow(title: "计  划", subtitle: "与 Palmi 确定计划并执行", systemImage: "checklist", action: onPlan)
                    .disabled(true)
                    .opacity(0.55)
                menuRow(title: "目  标", subtitle: "设立目标让 Palmi 完成", systemImage: "target", action: onGoal)
                    .disabled(true)
                    .opacity(0.55)
                menuRow(title: "深度研究", subtitle: "让 Palmi 进行深度研究", systemImage: "sparkle.magnifyingglass", action: onResearch)
                    .disabled(true)
                    .opacity(0.55)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color.white.opacity(0.16))
                .glassEffect(
                    .regular.tint(Color.white.opacity(0.30)),
                    in: RoundedRectangle(cornerRadius: 30, style: .continuous)
                )
                .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
        }
    }

    private func topButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 24)

                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func menuRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)

                Text(title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: 82, alignment: .leading)

                Text(subtitle)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct PalmiAttachmentUnavailableSheet: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(message)
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Button("关闭", action: onDismiss)
                .font(.body.weight(.semibold))
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .presentationDetents([.height(220)])
    }
}

private struct PalmiCameraPicker: UIViewControllerRepresentable {
    let onFinish: (WorkspaceImportedAttachment?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.delegate = context.coordinator
        controller.sourceType = .camera
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onFinish: (WorkspaceImportedAttachment?) -> Void

        init(onFinish: @escaping (WorkspaceImportedAttachment?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
        ) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.92) else {
                onFinish(nil)
                return
            }

            onFinish(
                WorkspaceImportedAttachment(
                    source: .camera,
                    preferredFilename: "camera-\(Self.timestamp()).jpg",
                    typeIdentifier: UTType.jpeg.identifier,
                    data: data
                )
            )
        }

        private static func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return formatter.string(from: .now)
        }
    }
}

private struct PalmiPhotoPicker: UIViewControllerRepresentable {
    let allowsMultipleSelection: Bool
    let onFinish: ([WorkspaceImportedAttachment]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = allowsMultipleSelection ? 0 : 1
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onFinish: ([WorkspaceImportedAttachment]) -> Void

        init(onFinish: @escaping ([WorkspaceImportedAttachment]) -> Void) {
            self.onFinish = onFinish
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                onFinish([])
                return
            }

            Task { @MainActor in
                let items = await loadAttachments(from: results)
                onFinish(items)
            }
        }

        private func loadAttachments(from results: [PHPickerResult]) async -> [WorkspaceImportedAttachment] {
            var attachments: [WorkspaceImportedAttachment] = []
            for (index, result) in results.enumerated() {
                guard let attachment = await loadAttachment(from: result.itemProvider, index: index) else {
                    continue
                }
                attachments.append(attachment)
            }
            return attachments
        }

        private func loadAttachment(
            from provider: NSItemProvider,
            index: Int
        ) async -> WorkspaceImportedAttachment? {
            let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
                UTType(identifier)?.conforms(to: .image) == true
            } ?? UTType.image.identifier

            guard let data = await loadData(from: provider, typeIdentifier: typeIdentifier) else {
                return nil
            }

            let filename = filename(
                suggestedName: provider.suggestedName,
                typeIdentifier: typeIdentifier,
                fallbackIndex: index
            )
            return WorkspaceImportedAttachment(
                source: .photoLibrary,
                preferredFilename: filename,
                typeIdentifier: typeIdentifier,
                data: data
            )
        }

        private func loadData(
            from provider: NSItemProvider,
            typeIdentifier: String
        ) async -> Data? {
            await withCheckedContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
        }

        private func filename(
            suggestedName: String?,
            typeIdentifier: String,
            fallbackIndex: Int
        ) -> String {
            let base = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "photo-\(Self.timestamp())-\(fallbackIndex + 1)"
            let rawName = (base?.isEmpty == false ? base : fallback) ?? fallback
            guard URL(fileURLWithPath: rawName).pathExtension.isEmpty else {
                return rawName
            }

            let ext = UTType(typeIdentifier)?.preferredFilenameExtension ?? "jpg"
            return "\(rawName).\(ext)"
        }

        private static func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return formatter.string(from: .now)
        }
    }
}

private struct PalmiDocumentPicker: UIViewControllerRepresentable {
    let allowsMultipleSelection: Bool
    let onFinish: ([WorkspaceImportedAttachment]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.allowsMultipleSelection = allowsMultipleSelection
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: ([WorkspaceImportedAttachment]) -> Void

        init(onFinish: @escaping ([WorkspaceImportedAttachment]) -> Void) {
            self.onFinish = onFinish
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish([])
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let attachments = urls.map { url in
                WorkspaceImportedAttachment(
                    source: .filePicker,
                    preferredFilename: url.lastPathComponent,
                    typeIdentifier: typeIdentifier(for: url),
                    fileURL: url
                )
            }
            onFinish(attachments)
        }

        private func typeIdentifier(for url: URL) -> String? {
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                return type.identifier
            }
            return UTType(filenameExtension: url.pathExtension)?.identifier
        }
    }
}
