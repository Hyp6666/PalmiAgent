import Foundation

enum AgentExternalToolName: String, CaseIterable, Codable, Hashable, Sendable {
    case read
    case edit
    case workspace
    case python
    case ocr
    case vision
    case webSearch = "web_search"
    case fetch
    case systemTime = "get_system_time"
    case location = "get_location"

    var localizedTitle: String {
        switch self {
        case .read:
            PalmiL10n.tr("tool.facade.read")
        case .edit:
            PalmiL10n.tr("tool.facade.edit")
        case .workspace:
            PalmiL10n.tr("tool.facade.workspace")
        case .python:
            "Python"
        case .ocr:
            "OCR"
        case .vision:
            PalmiL10n.tr("tool.facade.vision")
        case .webSearch:
            PalmiL10n.tr("tool.facade.webSearch")
        case .fetch:
            PalmiL10n.tr("tool.facade.fetch")
        case .systemTime:
            ToolActionID.getCurrentDateTime.localizedTitleForUI
        case .location:
            ToolActionID.requestLocation.localizedTitleForUI
        }
    }
}

struct AgentExternalToolFacade: Identifiable, Hashable, Sendable {
    let name: AgentExternalToolName
    let backingActionIDs: [ToolActionID]

    var id: AgentExternalToolName { name }
    var modelToolName: String { name.rawValue }
    var localizedTitle: String { name.localizedTitle }
}

struct AgentExternalToolResolution: Sendable {
    let facade: AgentExternalToolFacade
    let action: ToolAction
}

enum AgentExternalToolFacadeCatalog {
    static let all: [AgentExternalToolFacade] = [
        .init(name: .read, backingActionIDs: [.fileRead]),
        .init(name: .edit, backingActionIDs: [.fileWrite, .fileAppend]),
        .init(name: .workspace, backingActionIDs: [.listDirectory, .fileManage]),
        .init(name: .python, backingActionIDs: [.runPython]),
        .init(name: .ocr, backingActionIDs: [.recognizeImageText]),
        .init(name: .vision, backingActionIDs: [.scanImageWithMultimodalModel]),
        .init(name: .webSearch, backingActionIDs: [.searchWeb]),
        .init(name: .fetch, backingActionIDs: [.fetchStaticWebPage]),
        .init(name: .systemTime, backingActionIDs: [.getCurrentDateTime]),
        .init(name: .location, backingActionIDs: [.requestLocation])
    ]

    static func availableFacades(from actions: [ToolAction]) -> [AgentExternalToolFacade] {
        let availableActionIDs = Set(actions.map(\.id))
        return all.filter { facade in
            facade.backingActionIDs.allSatisfy(availableActionIDs.contains)
        }
    }

    static func facade(named name: String) -> AgentExternalToolFacade? {
        if let canonicalName = AgentExternalToolName(rawValue: name) {
            return all.first { $0.name == canonicalName }
        }
        guard let legacyActionID = ToolActionID(rawValue: name) else {
            return nil
        }
        return facade(backing: legacyActionID)
    }

    static func facade(backing actionID: ToolActionID) -> AgentExternalToolFacade? {
        all.first { $0.backingActionIDs.contains(actionID) }
    }

    static func canonicalToolName(for actionID: ToolActionID) -> String {
        facade(backing: actionID)?.modelToolName ?? actionID.rawValue
    }

    static func localizedTitle(for toolName: String) -> String? {
        if let facade = facade(named: toolName) {
            return facade.localizedTitle
        }
        guard let actionID = ToolActionID(rawValue: toolName) else {
            return nil
        }
        return actionID.localizedTitleForUI
    }

    static func resolve(
        toolName: String,
        arguments: ToolArguments,
        actions: [ToolAction]
    ) throws -> AgentExternalToolResolution {
        guard let facade = facade(named: toolName) else {
            throw AppError.invalidState("未知工具：\(toolName)")
        }

        let actionID: ToolActionID
        if let legacyActionID = ToolActionID(rawValue: toolName),
           facade.backingActionIDs.contains(legacyActionID) {
            actionID = legacyActionID
        } else {
            actionID = try resolvedActionID(for: facade, arguments: arguments)
        }

        guard let action = actions.first(where: { $0.id == actionID }) else {
            throw AppError.invalidState("工具当前未启用：\(facade.modelToolName)")
        }
        try validate(arguments: arguments, for: facade.name, actionID: actionID)
        return AgentExternalToolResolution(facade: facade, action: action)
    }

    private static func resolvedActionID(
        for facade: AgentExternalToolFacade,
        arguments: ToolArguments
    ) throws -> ToolActionID {
        switch facade.name {
        case .edit:
            switch try normalizedOperation(arguments) {
            case "write":
                return .fileWrite
            case "append":
                return .fileAppend
            default:
                throw AppError.invalidState("edit.operation 只支持 write 或 append。")
            }
        case .workspace:
            let operation = try normalizedOperation(arguments)
            if operation == "list" {
                return .listDirectory
            }
            guard ["mkdir", "delete", "move", "rename", "copy", "info", "exists"].contains(operation) else {
                throw AppError.invalidState("workspace.operation 不受支持：\(operation)")
            }
            return .fileManage
        default:
            guard let actionID = facade.backingActionIDs.first else {
                throw AppError.invalidState("工具没有可执行的底层动作：\(facade.modelToolName)")
            }
            return actionID
        }
    }

    private static func validate(
        arguments: ToolArguments,
        for facadeName: AgentExternalToolName,
        actionID: ToolActionID
    ) throws {
        switch facadeName {
        case .edit:
            _ = try arguments.requiredString("path")
            _ = try arguments.requiredString("content")
        case .workspace:
            if actionID == .listDirectory {
                return
            }
            let operation = try normalizedOperation(arguments)
            _ = try arguments.requiredString("path")
            if ["move", "rename", "copy"].contains(operation) {
                _ = try arguments.requiredString("destination")
            }
        default:
            break
        }
    }

    private static func normalizedOperation(_ arguments: ToolArguments) throws -> String {
        try arguments.requiredString("operation")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
