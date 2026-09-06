import Foundation

/// A model-scoped protocol contract. The opaque model ID only isolates evidence; it is never
/// interpreted. Explicit endpoint paths are authoritative; otherwise a successful protocol is
/// remembered for the exact profile, normalized endpoint fingerprint, and opaque model ID.
final class LLMWireProtocolContractStore {
    private struct Record: Codable, Equatable {
        let profileID: UUID
        let endpointFingerprint: String
        let modelID: String
        let wireProtocol: LLMWireProtocol
        let updatedAt: Date
    }

    static let storageKey = "palmi.llm.wire-protocol-contracts.v2"
    static let unsupportedEndpointStatusCodes: Set<Int> = [404, 405, 415, 501]
    static let cacheTTL: TimeInterval = 24 * 60 * 60

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let cacheTTL: TimeInterval
    private let now: () -> Date

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = LLMWireProtocolContractStore.storageKey,
        cacheTTL: TimeInterval = LLMWireProtocolContractStore.cacheTTL,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.cacheTTL = cacheTTL
        self.now = now
    }

    func protocolForRequest(
        profileID: UUID,
        modelID: String,
        endpoints: OpenAICompatibleEndpointResolution
    ) -> LLMWireProtocol {
        if let locked = endpoints.lockedWireProtocol {
            return locked
        }
        let storedRecords = records()
        let matchingRecord = storedRecords.first {
            $0.profileID == profileID
                && $0.endpointFingerprint == endpoints.endpointFingerprint
                && $0.modelID == modelID
        }
        guard let matchingRecord else { return .responses }
        if now().timeIntervalSince(matchingRecord.updatedAt) < cacheTTL {
            return matchingRecord.wireProtocol
        }
        persist(storedRecords.filter {
            !($0.profileID == profileID
                && $0.endpointFingerprint == endpoints.endpointFingerprint
                && $0.modelID == modelID)
        })
        return .responses
    }

    func fallbackProtocol(
        afterHTTPStatus statusCode: Int,
        attemptedProtocol: LLMWireProtocol,
        profileID: UUID,
        modelID: String,
        endpoints: OpenAICompatibleEndpointResolution
    ) -> LLMWireProtocol? {
        guard endpoints.lockedWireProtocol == nil,
              Self.unsupportedEndpointStatusCodes.contains(statusCode) else {
            return nil
        }
        switch attemptedProtocol {
        case .responses:
            return .chatCompletions
        case .chatCompletions:
            return .anthropicMessages
        case .anthropicMessages:
            return nil
        }
    }

    /// Handles a 2xx response whose body cannot be decoded as a Responses API payload.
    /// Payload classification belongs to the codec; this store only applies the same bounded,
    /// model-scoped automatic fallback and never overrides an explicit endpoint path.
    func fallbackProtocolAfterIncompatiblePayload(
        attemptedProtocol: LLMWireProtocol,
        profileID: UUID,
        modelID: String,
        endpoints: OpenAICompatibleEndpointResolution
    ) -> LLMWireProtocol? {
        // A syntactically unexpected 2xx body is not evidence that the endpoint itself is
        // unsupported. Switching protocols here can duplicate a completed generation or tool
        // call, so automatic negotiation is intentionally limited to HTTP endpoint errors.
        nil
    }

    func recordSuccess(
        protocol wireProtocol: LLMWireProtocol,
        profileID: UUID,
        modelID: String,
        endpoints: OpenAICompatibleEndpointResolution
    ) {
        guard endpoints.lockedWireProtocol == nil else { return }
        let storedRecords = records()
        let existing = storedRecords.first {
            $0.profileID == profileID
                && $0.endpointFingerprint == endpoints.endpointFingerprint
                && $0.modelID == modelID
        }
        let contractTimestamp = existing.flatMap {
            $0.wireProtocol == wireProtocol
                && now().timeIntervalSince($0.updatedAt) < cacheTTL
                ? $0.updatedAt
                : nil
        } ?? now()
        var updatedRecords = storedRecords.filter {
            !($0.profileID == profileID
                && $0.endpointFingerprint == endpoints.endpointFingerprint
                && $0.modelID == modelID)
        }
        updatedRecords.append(
            Record(
                profileID: profileID,
                endpointFingerprint: endpoints.endpointFingerprint,
                modelID: modelID,
                wireProtocol: wireProtocol,
                updatedAt: contractTimestamp
            )
        )
        updatedRecords.sort { $0.updatedAt > $1.updatedAt }
        if updatedRecords.count > 64 {
            updatedRecords.removeLast(updatedRecords.count - 64)
        }
        persist(updatedRecords)
    }

    func clear(profileID: UUID) {
        persist(records().filter { $0.profileID != profileID })
    }

    private func records() -> [Record] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private func persist(_ records: [Record]) {
        guard !records.isEmpty else {
            userDefaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}
