import CryptoKit
import Foundation

enum DocumentIOHashing {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ string: String) -> String { sha256(Data(string.utf8)) }

    static func fastFingerprint(url: URL, relativePath: String, isDirectory: Bool) throws -> String {
        if isDirectory {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                return sha256(relativePath)
            }
            var records: [String] = []
            while let item = enumerator.nextObject() as? URL, records.count < 20_000 {
                let values = try item.resourceValues(forKeys: Set(keys))
                let path = String(item.path.dropFirst(url.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                records.append("\(path)|\(values.isDirectory == true ? "d" : "f")|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
            return sha256(relativePath + "\n" + records.sorted().joined(separator: "\n"))
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let first = try handle.read(upToCount: 64 * 1024) ?? Data()
        let size = UInt64(values.fileSize ?? 0)
        if size > 64 * 1024 { try handle.seek(toOffset: size - 64 * 1024) }
        let last = try handle.read(upToCount: 64 * 1024) ?? Data()
        var data = Data("\(relativePath)|\(size)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|".utf8)
        data.append(first); data.append(last)
        return sha256(data)
    }
}
