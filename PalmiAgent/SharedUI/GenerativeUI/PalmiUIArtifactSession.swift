import Foundation
import Observation

@MainActor @Observable
final class PalmiUIArtifactSession {
    let validated: PalmiUIValidatedArtifact
    private(set) var state: [String: PalmiUIValue]
    private(set) var saveFailed = false
    private(set) var snapshotFailed = false
    private(set) var actionPending = false
    private(set) var snapshotAvailable = false
    private(set) var reloadID = UUID()
    @ObservationIgnored private let workspaceURL: URL
    @ObservationIgnored private let messageID: UUID
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var stateGeneration = 0
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var snapshotToken: UUID?
    @ObservationIgnored private var snapshotProvider: (() async throws -> [String: PalmiUIValue])?
    var stateRevision: Int { stateGeneration }

    init(validated: PalmiUIValidatedArtifact, messageID: UUID, workspaceURL: URL) {
        self.validated = validated; self.messageID = messageID; self.workspaceURL = workspaceURL
        self.state = validated.artifact.defaults
    }

    func loadIfNeeded() async {
        guard !loaded else { return }; loaded = true
        let generation = stateGeneration
        do {
            let url = try stateURL(create: false)
            if let restored = await Task.detached(priority: .utility, operation: { PalmiUIStateIO.load(url) }).value,
               generation == stateGeneration {
                state = normalize(restored)
            }
        } catch { /* A missing/corrupt sidecar never prevents reading the answer. */ }
    }

    func registerSnapshotProvider(token: UUID, provider: @escaping () async throws -> [String: PalmiUIValue]) {
        snapshotToken = token; snapshotProvider = provider
        snapshotAvailable = true
    }

    func removeSnapshotProvider(token: UUID) {
        guard snapshotToken == token else { return }
        snapshotToken = nil; snapshotProvider = nil
        snapshotAvailable = false
    }

    func captureLatestState() async -> Bool {
        guard !actionPending else { return false }
        if validated.artifact.kind == .native { flush(); return true }
        guard let snapshotProvider else { snapshotFailed = true; return false }
        let capturedReloadID = reloadID
        let capturedProviderToken = snapshotToken
        actionPending = true
        defer { actionPending = false }
        do {
            let snapshot = try await snapshotProvider()
            guard capturedReloadID == reloadID, capturedProviderToken == snapshotToken else { return false }
            replaceState(snapshot)
            snapshotFailed = false; flush(); return true
        } catch { snapshotFailed = true; return false }
    }

    func acceptDetachedSnapshot(_ snapshot: [String: PalmiUIValue], ifRevision revision: Int) {
        guard stateGeneration == revision else { return }
        replaceState(snapshot); flush()
    }

    func set(_ value: PalmiUIValue, for key: String) {
        var replacement = state; replacement[key] = value
        replaceState(replacement)
    }

    func replaceState(_ replacement: [String: PalmiUIValue]) {
        guard (try? PalmiUIValidator.validateState(replacement)) != nil else { return }
        let normalized = normalize(replacement)
        guard normalized != state else { return }
        stateGeneration += 1
        state = normalized
        scheduleSave()
    }

    func reset() {
        stateGeneration += 1
        state = validated.artifact.defaults
        reloadID = UUID()
        scheduleSave()
    }

    func reload() {
        // Detached replies also carry this revision, so reloading invalidates every older writer.
        stateGeneration += 1
        reloadID = UUID()
    }

    func snapshotJSON() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// The receiver only puts this text into the draft; it must not call send().
    func followUpDraft(prefix: String? = nil) -> String {
        let request = (prefix?.isEmpty == false ? prefix! : PalmiL10n.tr("ui.followUp"))
        return "\(request)\n\n[\(validated.artifact.title)]\n```json\n\(snapshotJSON())\n```"
    }

    func flush() {
        saveTask?.cancel(); saveTask = nil
        do {
            let bytes = try JSONEncoder().encode(state)
            guard bytes.count <= PalmiUIValidator.maximumStateBytes else { return }
            let url = try stateURL(create: true)
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
            saveFailed = false
        } catch { saveFailed = true }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func stateURL(create: Bool) throws -> URL {
        let base = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        var directory = base
        for component in [".files", ".palmi-ui-state", messageID.uuidString] {
            directory.appendPathComponent(component, isDirectory: true)
            let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true,
                  directory.resolvingSymlinksInPath().pathComponents.starts(with: base.pathComponents) else {
                throw PalmiUIValidationError.invalid("Invalid UI state directory")
            }
        }
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let filename = PalmiUIValidator.digest(validated.artifact.id + ":" + validated.revision) + ".json"
        let url = directory.appendingPathComponent(filename)
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw PalmiUIValidationError.invalid("Invalid UI state file")
        }
        return url
    }

    private func normalize(_ candidate: [String: PalmiUIValue]) -> [String: PalmiUIValue] {
        guard validated.artifact.kind == .native else { return candidate }
        var result = validated.artifact.defaults
        for (key, original) in validated.artifact.defaults {
            guard let value = candidate[key] else { continue }
            switch (original, value) {
            case (.number, .number), (.bool, .bool), (.string, .string): result[key] = value
            default: break
            }
        }
        func normalizeNodes(_ nodes: [PalmiUINode]) {
            for node in nodes {
                if let key = node.stateKey {
                    switch node.type {
                    case .slider:
                        if let value = result[key]?.number, let minimum = node.minimum, let maximum = node.maximum {
                            result[key] = .number(min(max(value, minimum), maximum))
                        }
                    case .select:
                        if let value = result[key]?.string, !(node.options ?? []).contains(value) { result[key] = validated.artifact.defaults[key] }
                    case .textField:
                        if let value = result[key]?.string { result[key] = .string(String(value.prefix(1_000))) }
                    default: break
                    }
                }
                normalizeNodes(node.children ?? [])
            }
        }
        normalizeNodes(validated.artifact.elements ?? [])
        return result
    }
}

nonisolated private enum PalmiUIStateIO {
    static func load(_ url: URL) -> [String: PalmiUIValue]? {
        do {
            let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  let count = properties.fileSize, count <= PalmiUIValidator.maximumStateBytes else { return nil }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard bytes.count <= PalmiUIValidator.maximumStateBytes else { return nil }
            let state = try JSONDecoder().decode([String: PalmiUIValue].self, from: bytes)
            try PalmiUIValidator.validateState(state)
            return state
        } catch { return nil }
    }
}
