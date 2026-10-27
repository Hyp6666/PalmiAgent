import SwiftUI
import UIKit

// 模型设置各页共用的组件：菜单行、模型字段块、检查块、探测。凡是同一语义的地方都用这里的同一个组件。

// MARK: - 菜单行

/// 列表里的一行：左侧标题是普通文字，只有右侧的当前值是菜单按钮。
struct ModelMenuRow<Content: View>: View {
    let title: String
    let value: String
    var icon: String? = nil
    var isProblem = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
            Spacer(minLength: 8)
            Menu {
                content()
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .lineLimit(1)
                        .foregroundStyle(isProblem ? Color.orange : Color.primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 固定选项的单选菜单行（服务商、协议、搜索引擎等）。
struct ChoiceMenuRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]

    var body: some View {
        ModelMenuRow(title: title, value: options.first { $0.value == selection }?.title ?? "") {
            ForEach(options.indices, id: \.self) { index in
                ModelMenuItem(title: options[index].title, selected: options[index].value == selection) {
                    selection = options[index].value
                }
            }
        }
    }
}

struct ModelMenuItem: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// 菜单内容：分组 → 模型。OAuth 分组单独放在“OAuth 分组”分节里。
struct ModelLibraryMenuItems: View {
    let library: ModelLibraryStore
    var followTitle: String? = nil
    let selectedID: UUID?
    var include: (ModelRecord) -> Bool = { !$0.imageGenerationOnly }
    let onSelect: (UUID?) -> Void

    var body: some View {
        if let followTitle {
            ModelMenuItem(title: followTitle, selected: selectedID == nil) { onSelect(nil) }
            Divider()
        }
        let groups = ModelLibraryPresentation.groups(library: library, models: library.state.models.filter(include))
        let oauth = groups.filter { library.state.connection($0.connectionID)?.chatGPTAccount != nil }
        ForEach(groups.filter { library.state.connection($0.connectionID)?.chatGPTAccount == nil }) { submenu($0, title: $0.title) }
        if !oauth.isEmpty {
            Section(PalmiL10n.tr("ml.oauth.groups")) {
                ForEach(oauth) { submenu($0, title: "Codex OAuth") }
            }
        }
    }

    private func submenu(_ group: ModelLibraryPresentation.Group, title: String) -> some View {
        Menu {
            ForEach(group.models) { model in
                ModelMenuItem(title: model.title, selected: selectedID == model.id) { onSelect(model.id) }
            }
        } label: {
            if group.models.contains(where: { $0.id == selectedID }) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

enum CodexOAuthLogo {
    /// 菜单里的图标需要固定尺寸，矢量资源按原尺寸会过大。
    @MainActor static func menuImage() -> Image {
        guard let source = UIImage(named: "CodexOAuthLogo") else { return Image(systemName: "person.badge.key") }
        let size = CGSize(width: 20, height: 20)
        let image = UIGraphicsImageRenderer(size: size).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        return Image(uiImage: image.withRenderingMode(.alwaysTemplate))
    }
}

// MARK: - 模型字段

extension LLMWireProtocolPreference {
    static var menuOptions: [(value: LLMWireProtocolPreference, title: String)] {
        allCases.map { ($0, ModelLibraryPresentation.protocolTitle($0)) }
    }
}

/// 协议 + 支持图片输入。模型详情、添加时的单个模型、批量导入都用这一块；批量时带一行说明。
struct ModelSettingsBlock: View {
    /// nil 时不显示协议（例如 OAuth 模型）。
    var wireProtocol: Binding<LLMWireProtocolPreference>?
    @Binding var supportsVision: Bool
    var footer: String? = nil

    var body: some View {
        Section {
            if let wireProtocol {
                ChoiceMenuRow(title: PalmiL10n.tr("model.connection.protocol.title"), selection: wireProtocol,
                              options: LLMWireProtocolPreference.menuOptions)
            }
            Toggle(PalmiL10n.tr("ml.model.imageInput"), isOn: $supportsVision)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

/// 单个模型的可编辑字段：模型 ID、备注名称，以及协议与图片输入。
struct ModelFieldsSections: View {
    @Binding var providerModelID: String
    var providerIDEditable = true
    @Binding var alias: String
    let aliasPrompt: String
    var wireProtocol: Binding<LLMWireProtocolPreference>?
    @Binding var supportsVision: Bool
    var onCommit: () -> Void = {}

    var body: some View {
        Section(PalmiL10n.tr("ml.model.providerID")) {
            TextField(PalmiL10n.tr("ml.model.providerID"), text: $providerModelID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.body.monospaced())
                .onSubmit(onCommit)
                .disabled(!providerIDEditable)
        }
        Section(PalmiL10n.tr("ml.model.name")) {
            TextField(PalmiL10n.tr("ml.model.name"), text: $alias, prompt: Text(aliasPrompt))
                .onSubmit(onCommit)
        }
        ModelSettingsBlock(wireProtocol: wireProtocol, supportsVision: $supportsVision)
    }
}

// MARK: - 检查

enum ModelCheckState: Equatable {
    case idle, running, passed, failed

    /// 批量结果：有失败即失败，全部通过才通过。
    static func aggregate(_ results: [Bool]) -> ModelCheckState {
        results.isEmpty ? .idle : (results.allSatisfy { $0 } ? .passed : .failed)
    }
}

/// 检查连通性 + 检查视觉。检查视觉先确认：会消耗额度，通过后自动开启图片输入，也可以不检查直接开关。
struct ModelChecksBlock: View {
    let connectivity: ModelCheckState
    let vision: ModelCheckState
    var disabled = false
    let onConnectivity: () async -> Void
    let onVision: () async -> Void
    @State private var confirmsVision = false

    var body: some View {
        Section {
            row(PalmiL10n.tr("ml.model.connectivity"), state: connectivity) { Task { await onConnectivity() } }
            row(PalmiL10n.tr("ml.model.checkVision"), state: vision) { confirmsVision = true }
        }
        .alert(PalmiL10n.tr("ml.model.checkVision"), isPresented: $confirmsVision) {
            Button(PalmiL10n.tr("common.cancel"), role: .cancel) {}
            Button(PalmiL10n.tr("ml.check.start")) { Task { await onVision() } }
        } message: {
            Text(PalmiL10n.tr("ml.check.visionNotice"))
        }
    }

    private func row(_ title: String, state: ModelCheckState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                switch state {
                case .idle: EmptyView()
                case .running: ProgressView()
                case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
                }
            }
        }
        .disabled(disabled || state == .running)
    }
}

/// 用一个来源（已保存或正在添加）直接探测某个模型 ID：连通性只发一句文字；视觉发一张纯红图片问颜色。
/// 结果只用于显示或开启图片输入，不影响模型使用。
@MainActor
struct ModelProbe {
    let runtime: any AgentModelRuntime
    let connection: ConnectionRecord
    let apiKey: String?

    init(runtime: any AgentModelRuntime, connection: ConnectionRecord, apiKey: String?) {
        self.runtime = runtime
        self.connection = connection
        self.apiKey = apiKey
    }

    /// 尚未保存的来源：用填写中的地址与 Key 临时构造。
    init(runtime: any AgentModelRuntime, endpoints: ConnectionEndpointConfiguration, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(runtime: runtime, connection: ConnectionRecord(
            id: UUID(), userLabel: nil, templateID: nil, authenticationKind: key.isEmpty ? .none : .apiKey,
            credentialReference: nil, chatGPTAccount: nil, credentialRevision: 1, endpointRevision: 1,
            endpoints: endpoints, createdAt: .now, updatedAt: .now
        ), apiKey: key)
    }

    func checkConnectivity(_ providerModelID: String, wireProtocol: LLMWireProtocolPreference) async throws {
        _ = try await send(providerModelID, wireProtocol: wireProtocol, message: .user("Reply with OK only."), vision: false)
    }

    func checkVision(_ providerModelID: String, wireProtocol: LLMWireProtocolPreference) async throws -> Bool {
        guard let image = Self.redImageDataURL() else { return false }
        var message = AgentModelMessage.user("What color is this image? Reply with one word.")
        message.imageDataURLs = [image]
        let reply = try await send(providerModelID, wireProtocol: wireProtocol, message: message, vision: true).lowercased()
        return reply.contains("red") || reply.contains("红")
    }

    private func send(_ providerModelID: String, wireProtocol: LLMWireProtocolPreference,
                      message: AgentModelMessage, vision: Bool) async throws -> String {
        var capabilities = ModelCapabilityRecord()
        if vision {
            capabilities.declarations[.visionInput] = ModelCapabilityEvidence(
                kind: .visionInput, state: .supported, source: .userDeclaration, evidenceKey: "probe", observedAt: .now, note: "probe"
            )
        }
        let model = ModelRecord(
            id: UUID(), connectionID: connection.id, providerModelID: providerModelID.trimmingCharacters(in: .whitespacesAndNewlines),
            userAlias: nil, remoteDisplayName: nil, canonicalID: nil, ownedBy: nil, imageGenerationOnly: false,
            capabilities: capabilities, parameters: ModelParameters(), legacyValidationStatus: .unvalidated,
            legacyValidationMessage: "", legacyValidatedAt: nil, createdAt: .now, updatedAt: .now,
            wireProtocolOverride: wireProtocol
        )
        guard let configuration = ModelLibraryStore.makeConfiguration(model: model, connection: connection, apiKey: apiKey, evidenceKey: "probe") else {
            throw AppError.invalidState(PalmiL10n.tr("model.error.baseURLScheme"))
        }
        let response = try await runtime.complete(AgentModelRequest(
            selection: AgentModelSelection(providerID: .customOpenAI, modelRole: .reasoningModel, reasoning: .disabled,
                                           configurationOverride: .resolved(configuration)),
            apiMessages: [message], tools: [], toolIntent: .none
        ))
        return response.message.textContent
    }

    private static func redImageDataURL() -> String? {
        let size = CGSize(width: 64, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9).map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
    }
}

// MARK: - 单个模型草稿（添加流程）

/// 添加时的模型草稿：保存或导入时写入模型库。
struct ModelDraftItem: Identifiable, Hashable {
    let id = UUID()
    var providerModelID: String
    var alias = ""
    var remoteDisplayName: String? = nil
    var canonicalID: String? = nil
    var ownedBy: String? = nil
    var wireProtocol: LLMWireProtocolPreference = .automatic
    var supportsVision = false

    init(providerModelID: String = "") {
        self.providerModelID = providerModelID
    }

    init(_ model: LLMDiscoveredModel, wireProtocol: LLMWireProtocolPreference, supportsVision: Bool) {
        providerModelID = model.id
        remoteDisplayName = model.remoteDisplayName
        canonicalID = model.canonicalID
        ownedBy = model.ownedBy
        self.wireProtocol = wireProtocol
        self.supportsVision = supportsVision
    }

    var title: String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (remoteDisplayName ?? providerModelID) : trimmed
    }

    var draft: ModelDraft {
        ModelDraft(providerModelID: providerModelID, userAlias: alias, remoteDisplayName: remoteDisplayName,
                   canonicalID: canonicalID, ownedBy: ownedBy, wireProtocol: wireProtocol,
                   supportsVision: supportsVision ? true : nil)
    }
}

/// 单个草稿模型的整页内容：字段 + 检查。手动添加与添加流程中的模型详情共用。
struct DraftModelForm: View {
    @Binding var item: ModelDraftItem
    let probe: ModelProbe?
    @State private var connectivity: ModelCheckState = .idle
    @State private var vision: ModelCheckState = .idle
    @State private var errorMessage: String?

    var body: some View {
        ModelFieldsSections(
            providerModelID: $item.providerModelID,
            alias: $item.alias,
            aliasPrompt: item.remoteDisplayName ?? PalmiL10n.tr("ml.optional"),
            wireProtocol: $item.wireProtocol,
            supportsVision: $item.supportsVision
        )
        ModelChecksBlock(
            connectivity: connectivity, vision: vision,
            disabled: probe == nil || item.providerModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ) {
            guard let probe else { return }
            connectivity = .running
            do { try await probe.checkConnectivity(item.providerModelID, wireProtocol: item.wireProtocol); connectivity = .passed }
            catch { connectivity = .failed; errorMessage = error.localizedDescription }
        } onVision: {
            guard let probe else { return }
            vision = .running
            do {
                let passed = try await probe.checkVision(item.providerModelID, wireProtocol: item.wireProtocol)
                vision = passed ? .passed : .failed
                if passed { item.supportsVision = true }
            } catch {
                vision = .failed
                errorMessage = error.localizedDescription
            }
        }
        .modelLibraryErrorAlert($errorMessage)
    }
}

extension View {
    func modelLibraryErrorAlert(_ message: Binding<String?>) -> some View {
        alert(PalmiL10n.tr("common.operationFailed"), isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button(PalmiL10n.tr("common.ok"), role: .cancel) {}
        } message: { Text(message.wrappedValue ?? "") }
    }
}
