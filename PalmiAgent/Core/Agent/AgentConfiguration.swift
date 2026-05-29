import Foundation

struct AgentConfiguration: Sendable {
    let userDefaults: UserDefaults

    static let `default` = AgentConfiguration(userDefaults: .standard)
}
