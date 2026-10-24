import SwiftUI

/// 模型库界面的展示辅助：标题、分组、状态说明。界面不保存任何配置副本，全部读写模型库。
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

    static func groups(library: ModelLibraryStore, models: [ModelRecord]? = nil) -> [Group] {
        let source = models ?? library.state.models
        return library.state.connections
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .compactMap { connection in
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
        case .visionInput: PalmiL10n.tr("ml.capability.vision")
        case .toolResultImages: PalmiL10n.tr("ml.capability.toolImages")
        case .imageGeneration: PalmiL10n.tr("ml.capability.imageGeneration")
        }
    }

    static func stateTitle(_ state: ModelCapabilityState) -> String {
        switch state {
        case .supported: PalmiL10n.tr("ml.capability.supported")
        case .unsupported: PalmiL10n.tr("ml.capability.unsupported")
        case .unknown: PalmiL10n.tr("ml.capability.unknown")
        }
    }

    static func sourceTitle(_ source: ModelCapabilitySource?) -> String {
        switch source {
        case .userDeclaration: PalmiL10n.tr("ml.capability.source.user")
        case .legacyDeclaration: PalmiL10n.tr("ml.capability.source.legacy")
        case .providerCatalog: PalmiL10n.tr("ml.capability.source.catalog")
        case .probe: PalmiL10n.tr("ml.capability.source.probe")
        case nil: PalmiL10n.tr("ml.capability.source.none")
        }
    }

    /// 凭据与连接状态：区分缺凭据、暂时不可读、读取失败与无需凭据。
    static func credentialStatus(_ connection: ConnectionRecord, library: ModelLibraryStore) -> (text: String, isProblem: Bool) {
        switch connection.authenticationKind {
        case .chatGPTOAuth: return (PalmiL10n.tr("ml.credential.oauth"), false)
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

    /// 主模型的真实解析状态：界面反映实际执行会用到的结果。
    static func mainModelStatus(_ library: ModelLibraryStore, scope: ModelLibraryScope? = nil) -> (title: String, detail: String?, isProblem: Bool) {
        switch library.resolveMainModel(scope: scope) {
        case .success(let resolved):
            return (resolved.snapshot.modelTitle, resolved.snapshot.connectionDisplayName, false)
        case .failure(let issue):
            let title: String
            switch library.state.defaultMainModel {
            case .selected(let id): title = library.state.model(id).map { $0.title } ?? PalmiL10n.tr("ml.binding.invalid")
            case .unconfigured, .explicitlyCleared: title = PalmiL10n.tr("common.notSelected")
            }
            return (title, issue.localizedDescription, true)
        }
    }

    static func usageBadges(_ model: ModelRecord, library: ModelLibraryStore) -> [String] {
        var badges: [String] = []
        if library.state.defaultMainModel.modelID == model.id { badges.append(PalmiL10n.tr("ml.badge.main")) }
        if library.state.toolBindings.vision.modelID == model.id { badges.append(PalmiL10n.tr("ml.badge.vision")) }
        if library.state.toolBindings.permissionReview.modelID == model.id { badges.append(PalmiL10n.tr("ml.badge.review")) }
        if model.imageGenerationOnly { badges.append(PalmiL10n.tr("ml.badge.imageOnly")) }
        return badges
    }
}

struct ModelLibraryBadge: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct ModelLibraryStatusLine: View {
    let text: String
    let isProblem: Bool

    var body: some View {
        Label(text, systemImage: isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(isProblem ? Color.orange : Color.secondary)
            .labelStyle(.titleAndIcon)
    }
}
