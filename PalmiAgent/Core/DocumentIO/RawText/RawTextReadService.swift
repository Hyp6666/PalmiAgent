import Foundation
import os

@MainActor
final class RawTextReadService {
    private let workspaceManager: WorkspaceManager
    private let signposter = OSSignposter(subsystem: "PalmiAgent", category: "DocumentIO")

    init(workspaceManager: WorkspaceManager) { self.workspaceManager = workspaceManager }

    func read(at path: String, start: Int = 0, count: Int = 20_000) async throws -> RawTextReadResult {
        guard start >= 0 else { throw RawTextReadError.invalidStart }
        guard (0...100_000).contains(count) else { throw RawTextReadError.invalidCount }
        let candidate = try workspaceManager.url(for: path)
        let root = try workspaceManager.ensureWorkspace()
        let url = try WorkspaceDocumentPathGuard.resolve(
            relativePath: path, candidate: candidate, workspaceRoot: root, allowPackageDirectory: false
        )
        let initial = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let detectState = signposter.beginInterval("read.detect_encoding")
        let sample = try Self.sample(url: url)
        let detected = try TextEncodingDetector.detect(sample: sample)
        signposter.endInterval("read.detect_encoding", detectState)
        let decodeState = signposter.beginInterval("read.decode_range")
        let result = try await Task.detached(priority: .utility) {
            try StreamingTextDecoder.read(url: url, detected: detected, start: start, count: count)
        }.value
        signposter.endInterval("read.decode_range", decodeState)
        let final = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard initial.fileSize == final.fileSize,
              initial.contentModificationDate == final.contentModificationDate else {
            throw RawTextReadError.fileChanged
        }
        return result
    }

    private nonisolated static func sample(url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 64 * 1024) ?? Data()
    }
}
