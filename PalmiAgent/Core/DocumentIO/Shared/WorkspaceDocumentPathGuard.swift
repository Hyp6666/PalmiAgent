import Foundation

struct WorkspaceDocumentPathGuard {
    static func resolve(
        relativePath: String,
        candidate: URL,
        workspaceRoot: URL,
        allowPackageDirectory: Bool
    ) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.contains("\0") else {
            throw RawTextReadError.notFound
        }
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let candidateComponents = resolved.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            throw RawTextReadError.outsideWorkspace
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw RawTextReadError.notFound
        }
        if isDirectory.boolValue {
            guard allowPackageDirectory else { throw RawTextReadError.isDirectory }
            return resolved
        }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw RawTextReadError.binaryFile }
        return resolved
    }
}
