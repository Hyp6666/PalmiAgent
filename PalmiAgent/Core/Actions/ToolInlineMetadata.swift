import Foundation

enum ToolInlineTargetKind: String, Codable, Sendable {
    case workspacePath
    case webURL
    case text
}

struct ToolInlineTarget: Codable, Sendable {
    let kind: ToolInlineTargetKind
    let displayText: String
    let value: String
}

enum ToolAuthorizationReviewState: String, Codable, Sendable {
    case reviewing
    case approved
    case rejected
    case needsUser = "needs_user"
}

struct ToolCallInlineMetadata: Codable, Sendable {
    let operation: String?
    let targets: [ToolInlineTarget]
    let trailingCount: Int?
    let detail: String?
    let reviewState: ToolAuthorizationReviewState?

    init(
        operation: String? = nil,
        targets: [ToolInlineTarget] = [],
        trailingCount: Int? = nil,
        detail: String? = nil,
        reviewState: ToolAuthorizationReviewState? = nil
    ) {
        self.operation = operation
        self.targets = targets
        self.trailingCount = trailingCount
        self.detail = detail
        self.reviewState = reviewState
    }

    func replacingReviewState(_ state: ToolAuthorizationReviewState?) -> ToolCallInlineMetadata {
        ToolCallInlineMetadata(
            operation: operation,
            targets: targets,
            trailingCount: trailingCount,
            detail: detail,
            reviewState: state
        )
    }
}

enum ToolCallInlineMetadataBuilder {
    static func make(
        toolName: String,
        actionID: ToolActionID? = nil,
        argumentsJSON: String
    ) -> ToolCallInlineMetadata? {
        guard let arguments = try? ToolArguments(jsonString: argumentsJSON) else { return nil }
        let facadeName = AgentExternalToolFacadeCatalog.facade(named: toolName)?.name
            ?? actionID.flatMap { AgentExternalToolFacadeCatalog.facade(backing: $0)?.name }

        switch facadeName {
        case .read, .breakDown, .edit, .ocr, .vision:
            return workspaceMetadata(path: arguments.string("path"))
        case .workspace:
            let operation = normalized(arguments.string("operation")) ?? "list"
            let source = arguments.string("path") ?? "."
            var targets = [workspaceTarget(source)]
            if let destination = normalized(arguments.string("destination")) {
                targets.append(workspaceTarget(destination))
            }
            return ToolCallInlineMetadata(operation: operation, targets: targets)
        case .python:
            if let scriptPath = normalized(arguments.string("script_path")) {
                return workspaceMetadata(path: scriptPath)
            }
            if let saveTo = normalized(arguments.string("save_to")) {
                return workspaceMetadata(path: saveTo)
            }
            return ToolCallInlineMetadata(operation: "inline_script")
        case .readSkill:
            return textMetadata(arguments.string("skill"))
        case .importSkill:
            return workspaceMetadata(path: arguments.string("path"))
        case .webSearch:
            return textMetadata(arguments.string("query"))
        case .fetch:
            let rawURLs = [arguments.string("url")].compactMap { $0 }
                + (arguments.stringArray("urls") ?? [])
            let targets = rawURLs.compactMap { webTarget($0) }
            return targets.isEmpty ? nil : ToolCallInlineMetadata(
                operation: targets.count > 1 ? "fetch_multiple" : nil,
                targets: Array(targets.prefix(1)),
                trailingCount: max(0, targets.count - 1)
            )
        case .systemTime, .location:
            return nil
        case nil:
            break
        }

        switch toolName {
        case TaskStateToolDefinitionFactory.toolName:
            let operation = normalized(arguments.string("operation"))
            let target = normalized(arguments.string("title"))
                ?? normalized(arguments.string("task_id"))
            return ToolCallInlineMetadata(
                operation: operation,
                targets: target.map { [plainTarget($0)] } ?? [],
                detail: normalized(arguments.string("status"))
            )
        case AgentInfrastructureToolDefinitionFactory.compactToolName:
            return textMetadata(arguments.string("preserve_text"))
        case SubagentToolDefinitionFactory.useAgentToolName:
            let operation = normalized(arguments.string("action"))
            var labels: [String] = []
            if operation == "spawn" {
                labels = (arguments.dictionaryArray("tasks") ?? []).compactMap { item in
                    normalized(item["title"] as? String) ?? normalized(item["task_id"] as? String)
                }
            } else if let target = normalized(arguments.string("target")) {
                labels = [target]
            } else {
                labels = arguments.stringArray("targets") ?? []
            }
            return ToolCallInlineMetadata(
                operation: operation,
                targets: labels.prefix(1).map { plainTarget($0) },
                trailingCount: max(0, labels.count - 1)
            )
        default:
            return nil
        }
    }

    static func workspaceMetadata(path: String?) -> ToolCallInlineMetadata? {
        guard let path = normalized(path) else { return nil }
        return ToolCallInlineMetadata(targets: [workspaceTarget(path)])
    }

    static func textMetadata(_ text: String?) -> ToolCallInlineMetadata? {
        guard let text = normalized(text) else { return nil }
        return ToolCallInlineMetadata(targets: [plainTarget(text)])
    }

    static func webMetadata(title: String, url: URL, trailingCount: Int = 0) -> ToolCallInlineMetadata {
        ToolCallInlineMetadata(
            targets: [
                ToolInlineTarget(
                    kind: .webURL,
                    displayText: normalized(title) ?? url.host ?? url.absoluteString,
                    value: url.absoluteString
                )
            ],
            trailingCount: max(0, trailingCount)
        )
    }

    static func taskMetadata(
        operation: String?,
        title: String?,
        status: String?
    ) -> ToolCallInlineMetadata {
        ToolCallInlineMetadata(
            operation: normalized(operation),
            targets: normalized(title).map { [plainTarget($0)] } ?? [],
            detail: normalized(status)
        )
    }

    private static func workspaceTarget(_ path: String) -> ToolInlineTarget {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileName = URL(fileURLWithPath: cleanPath).lastPathComponent
        return ToolInlineTarget(
            kind: .workspacePath,
            displayText: fileName.isEmpty ? cleanPath : fileName,
            value: cleanPath
        )
    }

    private static func webTarget(_ rawValue: String) -> ToolInlineTarget? {
        guard let url = URL(string: rawValue), let scheme = url.scheme, ["http", "https"].contains(scheme) else {
            return nil
        }
        return ToolInlineTarget(
            kind: .webURL,
            displayText: url.host ?? url.absoluteString,
            value: url.absoluteString
        )
    }

    private static func plainTarget(_ value: String) -> ToolInlineTarget {
        ToolInlineTarget(kind: .text, displayText: value, value: value)
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
