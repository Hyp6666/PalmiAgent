import SwiftUI

/// 模型库界面的展示辅助：标题、分组、状态。界面不保存任何配置副本，全部读写模型库。
@MainActor
enum ModelLibraryPresentation {
    struct Group: Identifiable {
        let connectionID: UUID
        let title: String
        let models: [ModelRecord]
        var id: UUID { connectionID }
    }

    static func modelTitle(_ model: ModelRecord, library: ModelLibraryStore) -> String {
        let connection = library.state.connection(model.connectionID)?.displayName ?? ""
        return connection.isEmpty ? model.title : "\(model.title) · \(connection)"
    }

    static func sortedConnections(_ library: ModelLibraryStore) -> [ConnectionRecord] {
        library.state.connections.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func groups(library: ModelLibraryStore, models: [ModelRecord]? = nil) -> [Group] {
        let source = models ?? library.state.models
        return sortedConnections(library).compactMap { connection in
            let items = source.filter { $0.connectionID == connection.id }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return items.isEmpty ? nil : Group(connectionID: connection.id, title: connection.displayName, models: items)
        }
    }

    static func protocolTitle(_ preference: LLMWireProtocolPreference) -> String {
        switch preference {
        case .automatic: PalmiL10n.tr("model.connection.protocol.automatic")
        case .responses: "Responses"
        case .chatCompletions: "Chat Completions"
        case .anthropicMessages: "Messages"
        }
    }

    static func capabilityTitle(_ kind: ModelCapabilityKind) -> String {
        switch kind {
        case .textGeneration: PalmiL10n.tr("ml.capability.text")
        case .toolCalls: PalmiL10n.tr("ml.capability.tools")
        case .visionInput: PalmiL10n.tr("tool.facade.vision")
        case .toolResultImages: PalmiL10n.tr("ml.capability.toolImages")
        case .imageGeneration: PalmiL10n.tr("image.generation")
        }
    }

    /// 凭据状态：区分缺凭据、暂时不可读、读取失败与无需凭据。
    static func credentialStatus(_ connection: ConnectionRecord, library: ModelLibraryStore) -> (text: String, isProblem: Bool) {
        switch connection.authenticationKind {
        case .chatGPTOAuth: return ("Codex OAuth", false)
        case .none: return (PalmiL10n.tr("ml.credential.none"), false)
        case .apiKey:
            switch library.credentialRead(for: connection) {
            case .present: return (library.maskedKey(for: connection) ?? PalmiL10n.tr("ml.credential.saved"), false)
            case .notFound: return (PalmiL10n.tr("ml.credential.missing"), true)
            case .temporarilyUnavailable: return (PalmiL10n.tr("ml.credential.locked"), true)
            case .failed: return (PalmiL10n.tr("ml.credential.failed"), true)
            }
        }
    }

    static func connectionNeedsAttention(_ connection: ConnectionRecord, library: ModelLibraryStore) -> Bool {
        credentialStatus(connection, library: library).isProblem
            || !library.state.blockingConflicts(for: .connection(connection.id)).isEmpty
    }

    /// 主模型的真实解析状态：界面反映实际执行会用到的结果。
    static func mainModelStatus(_ library: ModelLibraryStore, scope: ModelLibraryScope? = nil) -> (title: String, isProblem: Bool) {
        switch library.resolveMainModel(scope: scope) {
        case .success(let resolved):
            return (resolved.snapshot.modelTitle, false)
        case .failure:
            switch library.state.defaultMainModel {
            case .selected(let id): return (library.state.model(id)?.title ?? PalmiL10n.tr("ml.binding.invalid"), true)
            case .unconfigured, .explicitlyCleared: return (PalmiL10n.tr("common.notSelected"), true)
            }
        }
    }

    /// 工具绑定的显示值：跟随主模型、模型名或已失效。
    static func toolBindingTitle(_ binding: ToolModelBinding, library: ModelLibraryStore) -> String {
        switch binding {
        case .followMainModel: PalmiL10n.tr("ml.tool.followMain")
        case .model(let id): library.state.model(id)?.title ?? PalmiL10n.tr("ml.binding.invalid")
        }
    }
}
