import Foundation

enum AppError: LocalizedError {
    case unsupported(String)
    case permissionDenied(String)
    case invalidState(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message),
             .permissionDenied(let message),
             .invalidState(let message),
             .operationFailed(let message):
            message
        }
    }
}
