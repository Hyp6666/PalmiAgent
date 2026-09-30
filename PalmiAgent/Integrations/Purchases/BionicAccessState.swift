import Foundation

/// In-memory authority shared only by StoreKit and the archive. Never read from
/// persona JSON, tool arguments, UserDefaults, imported files, or model output.
nonisolated final class BionicAccessState: @unchecked Sendable {
    private let lock = NSLock()
    private var fullAccess = false

    var hasFullAccess: Bool { lock.withLock { fullAccess } }
    var customRoleLimit: Int { hasFullAccess ? 99 : 2 }

    func replaceVerifiedEntitlement(_ fullAccess: Bool) {
        lock.withLock { self.fullAccess = fullAccess }
    }

    func requirePro() throws {
        guard hasFullAccess else { throw BionicFailure("purchaseRequired") }
    }
}
