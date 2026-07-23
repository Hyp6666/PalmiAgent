import Foundation

enum BreakdownManifestStore {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()

    static func load(from bundleURL: URL) throws -> BreakdownManifest? {
        let url = bundleURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(BreakdownManifest.self, from: Data(contentsOf: url))
    }
    static func save(_ manifest: BreakdownManifest, to bundleURL: URL) throws {
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
