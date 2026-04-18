import Foundation
import FoundationModels

@MainActor
final class FoundationModelService {
    func summarize(_ text: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw AppError.unsupported("端上模型当前不可用：\(String(describing: model.availability))。")
        }

        let session = LanguageModelSession(model: model)
        let response = try await session.respond(
            to: """
            请用中文输出三条要点，总结下面内容，不要加标题：
            \(text)
            """
        )
        return response.content
    }
}
