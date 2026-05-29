import Foundation

enum WorkspaceAttachmentSource: String, Codable, Sendable {
    case camera
    case photoLibrary
    case filePicker

    var title: String {
        switch self {
        case .camera:
            return "相机"
        case .photoLibrary:
            return "照片"
        case .filePicker:
            return "文件"
        }
    }
}

struct WorkspaceImportedAttachment: Sendable {
    let source: WorkspaceAttachmentSource
    let preferredFilename: String
    let typeIdentifier: String?
    let data: Data?
    let fileURL: URL?

    init(
        source: WorkspaceAttachmentSource,
        preferredFilename: String,
        typeIdentifier: String? = nil,
        data: Data? = nil,
        fileURL: URL? = nil
    ) {
        self.source = source
        self.preferredFilename = preferredFilename
        self.typeIdentifier = typeIdentifier
        self.data = data
        self.fileURL = fileURL
    }
}

struct WorkspaceStoredAttachment: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let originalFilename: String
    let storedFilename: String
    let relativePath: String
    let source: WorkspaceAttachmentSource
    let typeIdentifier: String?
    let byteCount: Int64
    let createdAt: Date
}

struct WorkspaceAttachmentBatch: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let createdAt: Date
    let relativePath: String
    let originalRelativePath: String
    let previewRelativePath: String
    let extractedRelativePath: String
    let attachments: [WorkspaceStoredAttachment]
}

struct WorkspaceAttachmentBatchMetadata: Codable, Sendable {
    let batch: WorkspaceAttachmentBatch
}
