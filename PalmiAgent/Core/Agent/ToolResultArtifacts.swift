import Foundation

/// 工具结果的明确预算（UTF-8 字节）。按执行器确认的 canonical actionID 选择，不靠展示名称反猜。
nonisolated enum ToolResultBudget {
    /// 给下一步有界工具结果预留的上下文空间（tokens）。
    static let nextStepReserveTokens = 16_000

    static func byteBudget(for actionID: ToolActionID?) -> Int? {
        guard let actionID else { return 12_000 }
        switch actionID {
        case .readSkill:
            // SkillIOService 已做包级上限；read_skill 契约要求默认调用返回完整 SKILL.md。
            return nil
        case .fetchStaticWebPage:
            return 64_000
        case .searchWeb, .fileRead, .listDirectory, .recognizeImageText, .scanImageWithMultimodalModel, .browser:
            return 48_000
        default:
            return 16_000
        }
    }
}

nonisolated enum ToolResultArtifactError: Error, LocalizedError, Equatable {
    case missing(String)
    case invalidRange
    case storageFailed(String)

    var errorDescription: String? {
        switch self {
        case .missing(let id): "工具结果产物 \(id) 不存在或已过期；原始结果不可恢复，请重新调用原工具。"
        case .invalidRange: "读取范围无效：start 必须是不超过总长度的非负字节偏移。"
        case .storageFailed(let message): "工具结果归档失败：\(message)"
        }
    }
}

/// 正文或大工具输出先完整保存为会话私有的不可变产物；后续分页复用产物，不重新联网。
@MainActor
final class ToolResultArtifactStore {
    private let workspaceManager: WorkspaceManager

    init(workspaceManager: WorkspaceManager) { self.workspaceManager = workspaceManager }

    struct Manifest: Codable {
        let artifactID: String
        let sha256: String
        let totalBytes: Int
        let actionID: String
        let source: String
        let contentType: String
        let createdAt: Date
    }

    func store(_ text: String, actionID: ToolActionID, source: String, contentType: String) throws -> Manifest {
        let data = Data(text.utf8)
        let sha = ModelLibraryDigest.sha256Hex(data)
        let id = "tr_" + String(sha.prefix(24))
        let directory = try workspaceManager.toolResultArtifactsDirectoryForCurrentThread()
        let body = directory.appendingPathComponent(id + ".txt")
        let manifestURL = directory.appendingPathComponent(id + ".json")
        let manifest = Manifest(artifactID: id, sha256: sha, totalBytes: data.count, actionID: actionID.rawValue,
                                source: source, contentType: contentType, createdAt: .now)
        if !FileManager.default.fileExists(atPath: body.path) {
            do {
                try data.write(to: body, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            } catch {
                throw ToolResultArtifactError.storageFailed(error.localizedDescription)
            }
        }
        return manifest
    }

    /// 同一 artifactID 与 hash 下分页可复现；产物不存在时返回明确错误，不返回空串冒充读完。
    func page(_ artifactID: String, start: Int, maxBytes: Int, preferredBreak: String? = nil) throws -> ToolResultPage {
        guard artifactID.range(of: "^tr_[0-9a-f]{24}$", options: .regularExpression) != nil else {
            throw ToolResultArtifactError.missing(artifactID)
        }
        let directory = try workspaceManager.toolResultArtifactsDirectoryForCurrentThread()
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(artifactID + ".txt")) else {
            throw ToolResultArtifactError.missing(artifactID)
        }
        let sha = ModelLibraryDigest.sha256Hex(data)
        guard artifactID == "tr_" + String(sha.prefix(24)) else { throw ToolResultArtifactError.missing(artifactID) }
        let bytes = [UInt8](data)
        guard start >= 0, start <= bytes.count else { throw ToolResultArtifactError.invalidRange }
        let range = UTF8Range.page(bytes, start: start, maxBytes: maxBytes, preferredBreak: preferredBreak.map { Array($0.utf8) })
        let text = String(decoding: bytes[range], as: UTF8.self)
        return ToolResultPage(artifactID: artifactID, sha256: sha, totalBytes: bytes.count, start: range.lowerBound, end: range.upperBound, text: text)
    }
}

/// 读取工具结果产物后续范围的基础设施工具。工具声明在支持它的会话中稳定注册。
enum ToolResultReaderTool {
    static let name = "read_tool_result"

    static var definition: AgentModelToolDefinition {
        AgentModelToolDefinition(function: AgentModelFunctionDefinition(
            name: name,
            description: "读取之前工具结果中被分页的剩余内容。只能读取本会话已保存的 artifact_id；start 为 UTF-8 字节偏移，通常使用上一页返回的 next_start。不会重新联网或重新执行原工具。",
            parameters: ToolJSONSchema.object(
                properties: [
                    "artifact_id": ToolJSONSchema.string(description: "工具结果中给出的 artifact_id。"),
                    "start": ToolJSONSchema.integer(description: "起始 UTF-8 字节偏移，使用 next_start。")
                ],
                required: ["artifact_id", "start"]
            )
        ))
    }
}
