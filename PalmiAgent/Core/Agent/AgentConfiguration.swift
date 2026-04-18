import Foundation

struct AgentConfiguration: Sendable {
    let maxIterations: Int
    let userDefaults: UserDefaults

    static let `default` = AgentConfiguration(maxIterations: 1000, userDefaults: .standard)
}
