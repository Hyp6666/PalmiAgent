import Foundation

enum WorkspaceAttachmentSource: String, Codable, Sendable {
    case camera
    case photoLibrary
    case filePicker

    var title: String {
        switch self {
        case .camera:
            return "\u{76f8}\u{673a}"
        case .photoLibrary:
            return "\u{7167}\u{7247}"
        case .filePicker:
            return "\u{6587}\u{4ef6}"
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
