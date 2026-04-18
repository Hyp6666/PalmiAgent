import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SpotlightService {
    func indexWorkspace(files: [URL]) async throws -> Int {
        let items = files.map { url in
            let attributes = CSSearchableItemAttributeSet(itemContentType: UTType.data.identifier)
            attributes.title = url.lastPathComponent
            attributes.contentDescription = "PalmiAgent 工作区文件"
            attributes.contentURL = url
            return CSSearchableItem(
                uniqueIdentifier: "workspace.\(url.lastPathComponent)",
                domainIdentifier: "com.hongyupeng.PalmiAgent.workspace",
                attributeSet: attributes
            )
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        return items.count
    }

    func clearIndex() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["com.hongyupeng.PalmiAgent.workspace"]) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
