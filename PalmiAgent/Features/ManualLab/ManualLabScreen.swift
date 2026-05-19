import SwiftUI

struct ManualLabScreen: View {
    @Bindable var store: ManualLabStore
    var onOpenChat: (() -> Void)?

    private let llmPromptExamples = [
        "帮我创建工作区并告诉我生成了什么",
        "打开相册让我选一张图片",
        "搜索附近景点",
        "给我发一条本地通知"
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private struct ProviderSection: Identifiable {
        let id: String
        let title: String
        let providers: [APIProviderID]
    }

    private let manualLabProviderSections: [ProviderSection] = [
        ProviderSection(id: "official", title: "官方直连", providers: [.deepseek, .glm, .qwen, .kimi, .minimax, .openai]),
        ProviderSection(id: "cloud", title: "云平台与厂商", providers: [.volcengine, .hunyuan, .qianfan, .stepfun, .azureOpenAI]),
        ProviderSection(id: "aggregator", title: "聚合与托管", providers: [.siliconflow, .modelscope, .openrouter]),
        ProviderSection(id: "local", title: "本地与自定义", providers: [.lmstudio, .ollama, .customOpenAI])
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                background

                ScrollView {
                    VStack(spacing: 24) {
                        summaryPanel
                        apiConfigurationPanel
                        naturalLanguageToolPanel

                        if let result = store.lastResult {
                            lastResultPanel(result)
                        }

                        ForEach(store.groupedActions, id: \.category.id) { section in
                            sectionPanel(section.category, actions: section.actions)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle("开发者模式")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onOpenChat?()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(item: $store.presentation) { presentation in
            switch presentation {
            case .imagePicker(_, let sourceType):
                ImagePickerBridge(sourceType: sourceType) { image in
                    store.handleImageResult(image)
                }
            case .documentScanner(_):
                DocumentScannerBridge { pageCount in
                    store.handleDocumentScan(pageCount)
                }
            case .textScanner(_):
                LiveTextScannerBridge { text in
                    store.handleTextScan(text)
                }
            case .safari(_, let options):
                SafariSheet(options: options)
            }
        }
        .sheet(item: $store.sharePayload) { payload in
            ShareSheet(items: [payload.url])
        }
    }

    private var summaryPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("这里是开发者模式。所有底层算子和调试能力都集中在这里，独立于正式聊天界面。")
                .font(.headline)

            HStack(spacing: 12) {
                StatCapsule(title: "已接通", value: store.liveCount, tint: .green)
                StatCapsule(title: "部分接通", value: store.partialCount, tint: .orange)
                StatCapsule(title: "LLM 暴露", value: store.exposedToolCount, tint: .cyan)
                StatCapsule(title: "模型接入", value: store.configuredProviderCount, tint: .blue)
            }
        }
        .padding(22)
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }

    private var apiConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("模型接入配置")
                        .font(.title3.weight(.bold))
                    Text("沿用同一套 provider 卡片：GLM、DeepSeek 走标准 API；LM Studio 走局域网发现和自动配对。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                configurationCountPill
            }

            activeProviderPicker

            providerConfigurationCard(for: store.activeProviderID)
        }
        .padding(22)
        .glassEffect(.regular.tint(.cyan.opacity(0.08)), in: .rect(cornerRadius: 32))
    }

    private var naturalLanguageToolPanel: some View {
        let snapshot = store.activeLLMSnapshot

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("自然语言工具调用")
                        .font(.title3.weight(.bold))
                    Text("这里走真实的 `LLM -> tool -> result` 链路。当前只做单次 tool call 验证，不做 agent 循环。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                configurationStatusBadge(isConfigured: snapshot.isConfigured)
            }

            HStack(spacing: 12) {
                configurationMetric(title: "当前 Provider", value: snapshot.provider.title, tint: .cyan)
                configurationMetric(title: "当前模式", value: snapshot.selectedAccessMode.title, tint: .teal)
                configurationMetric(title: "当前模型", value: snapshot.selectedModel.title, tint: .indigo)
                configurationMetric(title: "可选工具", value: "\(store.exposedToolCount)", tint: .green)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white.opacity(0.08))

                TextEditor(text: $store.naturalLanguagePrompt)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                if store.naturalLanguagePrompt.isEmpty {
                    Text("输入一句自然语言，比如“打开相册让我选图”或“搜索附近景点”。模型会自己选择最匹配的一个工具。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(llmPromptExamples, id: \.self) { example in
                        Button(example) {
                            store.usePromptExample(example)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.08), in: Capsule())
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    store.runNaturalLanguageToolCall()
                } label: {
                    HStack(spacing: 8) {
                        if store.isRunningNaturalLanguageCall {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                        Text(store.isRunningNaturalLanguageCall ? "调用中" : "执行单次 Tool Call")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(!store.canSubmitNaturalLanguagePrompt)

                Text("只验证一次真实调用，不做多轮 agent。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let llmStatusMessage = store.llmStatusMessage {
                Text(llmStatusMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(store.isRunningNaturalLanguageCall ? .secondary : .primary)
            }

            if let llmStreamingPreview = store.llmStreamingPreview, !llmStreamingPreview.isEmpty {
                Text(llmStreamingPreview)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            if let session = store.llmSessions.first {
                llmSessionCard(session)
            }
        }
        .padding(22)
        .glassEffect(.regular.tint(.teal.opacity(0.10)), in: .rect(cornerRadius: 32))
    }

    private func lastResultPanel(_ result: ToolResult) -> some View {
        let presentationKind = result.actionID.presentationKind

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近一次执行")
                    .font(.headline)
                Spacer()
                Text(result.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.status == .failure ? .red : result.status == .warning ? .orange : .green)
            }
            Text(result.title)
                .font(.title3.weight(.bold))
            Text(result.summary)
                .font(.body)
            Text(presentationKind == .data ? result.details : summarizedDetails(result.details, for: presentationKind))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .glassEffect(.regular.tint(.teal.opacity(0.12)), in: .rect(cornerRadius: 30))
    }

    private func sectionPanel(_ category: ToolCategory, actions: [ToolAction]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(category.title)
                    .font(.title3.weight(.bold))
                Text(category.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(actions) { action in
                    actionCard(action)
                }
            }
        }
        .padding(22)
        .glassEffect(.regular.tint(.white.opacity(0.04)), in: .rect(cornerRadius: 32))
    }

    private var activeProviderPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前聊天默认 Provider")
                .font(.subheadline.weight(.semibold))

            Menu {
                ForEach(manualLabProviderSections) { section in
                    Section(section.title) {
                        ForEach(section.providers) { providerID in
                            Button {
                                activeProviderBinding.wrappedValue = providerID
                            } label: {
                                Label(
                                    providerID.vendorTitle,
                                    systemImage: store.activeProviderID == providerID ? "checkmark.circle.fill" : "circle"
                                )
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(store.activeProviderID.vendorTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func providerConfigurationCard(for providerID: APIProviderID) -> some View {
        let snapshot = store.snapshot(for: providerID)
        let selectedAccessMode = store.selectedAccessMode(for: providerID)
        let selectedModel = store.selectedModel(for: providerID)
        let feedback = store.feedback(for: providerID)
        let isActiveProvider = store.activeProviderID == providerID
        let keyStatusTitle = snapshot.provider.secretRequirement == .optional ? "Token 状态" : "Key 状态"
        let keyStatusValue = snapshot.hasAPIKey ? (snapshot.maskedAPIKey ?? "已保存") : "未配置"

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(snapshot.provider.title)
                            .font(.headline)
                        if isActiveProvider {
                            Text("当前默认")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.cyan.opacity(0.14), in: Capsule())
                        }
                    }
                }
                Spacer(minLength: 12)
                configurationStatusBadge(isConfigured: snapshot.isConfigured)
            }

            HStack(spacing: 12) {
                configurationMetric(
                    title: "接入模式",
                    value: selectedAccessMode.title,
                    tint: .teal
                )
                configurationMetric(
                    title: snapshot.provider.supportsManualModelSelection ? "已选模型" : "当前配对",
                    value: selectedModel.title,
                    tint: .blue
                )
                configurationMetric(
                    title: keyStatusTitle,
                    value: keyStatusValue,
                    tint: snapshot.hasAPIKey ? .green : .orange
                )
            }

            if let updatedAt = snapshot.updatedAt {
                Text("最近更新：\(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("接入方式")
                    .font(.subheadline.weight(.semibold))
                Picker("接入方式", selection: accessModeBinding(for: providerID)) {
                    ForEach(store.availableAccessModes(for: providerID)) { accessMode in
                        Text(accessMode.title).tag(accessMode.id)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    configurationMetric(title: "端点", value: snapshot.endpointDisplayValue, tint: .purple)
                    configurationMetric(title: "口径", value: selectedAccessMode.badgeText, tint: .mint)
                }
            }

            if snapshot.provider.endpointStrategy == .profileManaged {
                profileManagedEndpointSection(for: providerID, snapshot: snapshot)
            }

            if snapshot.provider.supportsManualModelSelection {
                VStack(alignment: .leading, spacing: 10) {
                    Text("模型")
                        .font(.subheadline.weight(.semibold))
                    Picker("模型", selection: modelBinding(for: providerID)) {
                        ForEach(store.availableModels(for: providerID)) { model in
                            Text(model.title).tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)

                    if store.supportsRemoteModelDiscovery(for: providerID) {
                        Button {
                            store.refreshRemoteModels(for: providerID)
                        } label: {
                            HStack(spacing: 8) {
                                if store.isFetchingRemoteModels(for: providerID) {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                }
                                Text(store.isFetchingRemoteModels(for: providerID) ? "检测中" : "检测模型")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isFetchingRemoteModels(for: providerID))
                    }
                }
            } else {
                automaticRemoteModelSection(for: providerID, snapshot: snapshot)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(snapshot.provider.secretLabel)
                    .font(.subheadline.weight(.semibold))
                SecureField(snapshot.provider.placeholder, text: apiKeyBinding(for: providerID))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            }

            HStack(spacing: 12) {
                Button("保存配置") {
                    store.saveAPIConfiguration(for: providerID)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)

                Button(snapshot.provider.secretRequirement == .optional ? "清空 Token" : "清空 API Key") {
                    store.clearAPIKey(for: providerID)
                }
                .buttonStyle(.bordered)
                .disabled(!snapshot.hasAPIKey)
            }

            if let feedback {
                Text(feedback.message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(feedback.isError ? .red : .green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            (isActiveProvider ? Color.cyan : Color.white).opacity(isActiveProvider ? 0.10 : 0.06),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
    }

    private func llmSessionCard(_ session: LLMToolSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近一次 LLM 调用")
                    .font(.headline)
                Spacer()
                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("用户输入")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(session.userPrompt)
                    .font(.body)
            }

            if !session.planningReply.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("前置")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(session.planningReply)
                        .font(.body)
                }
            }

            if let step = session.steps.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text("执行的工具")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 12) {
                        configurationStatusBadge(isConfigured: step.result.status == .success)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.action.title)
                                .font(.subheadline.weight(.semibold))
                            Text(step.result.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if step.action.id.presentationKind != .data {
                                Text(summarizedDetails(step.result.details, for: step.action.id.presentationKind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("模型答复")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(session.assistantReply)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func summarizedDetails(_ details: String, for kind: ToolPresentationKind) -> String {
        switch kind {
        case .data:
            return details
        case .action:
            return details
        case .interactive:
            return details
        }
    }

    private func actionCard(_ action: ToolAction) -> some View {
        Button {
            store.run(action)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(action.title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    StatusBadge(availability: action.availability)
                }

                Text(action.effect)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 8)

                Text(action.details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)

                if store.runningActionID == action.id {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .padding(18)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        }
        .buttonStyle(.plain)
    }

    private var configurationCountPill: some View {
        Text("\(store.configuredProviderCount)/\(store.totalProviderCount) 已配置")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.cyan.opacity(0.24), in: Capsule())
    }

    private func configurationStatusBadge(isConfigured: Bool) -> some View {
        Text(isConfigured ? "已配置" : "待配置")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((isConfigured ? Color.green : Color.orange).opacity(0.24), in: Capsule())
    }

    private func configurationMetric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func profileManagedEndpointSection(
        for providerID: APIProviderID,
        snapshot: APIProviderConfigurationSnapshot
    ) -> some View {
        let supportsDiscovery = store.supportsServerDiscovery(for: providerID)
        let discoveredServers = store.discoveredLMStudioServers(for: providerID)
        let selectedServer = store.selectedLMStudioServer(for: providerID)

        VStack(alignment: .leading, spacing: 12) {
            Text(supportsDiscovery ? "本地服务器" : "API Endpoint")
                .font(.subheadline.weight(.semibold))

            TextField("Endpoint", text: customBaseURLBinding(for: providerID))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if supportsDiscovery {
                Button {
                    store.autoConfigureLMStudio(for: providerID)
                } label: {
                    HStack(spacing: 8) {
                        if store.isDiscoveringLMStudioServers(for: providerID) {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(store.isDiscoveringLMStudioServers(for: providerID) ? "配置中" : "自动配置")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(store.isDiscoveringLMStudioServers(for: providerID))
            }

            if supportsDiscovery, let selectedServer {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前已配对：\(selectedServer.displayName)")
                        .font(.footnote.weight(.semibold))

                    HStack(spacing: 10) {
                        if selectedServer.requiresAuthentication {
                            capsuleLabel("需要鉴权", tint: .orange)
                        }
                        if selectedServer.supportsToolUse {
                            capsuleLabel("支持工具调用", tint: .green)
                        }
                        if selectedServer.supportsVision {
                            capsuleLabel("支持视觉", tint: .blue)
                        }
                    }

                    Text(selectedServer.selectedModelSummary ?? snapshot.endpointDisplayValue)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            if supportsDiscovery, !discoveredServers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("发现结果")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(discoveredServers) { server in
                        Button {
                            store.selectLMStudioServer(server, for: providerID)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(server.selectedModelTitle ?? "等待服务端返回模型")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: selectedServer?.id == server.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedServer?.id == server.id ? .cyan : .secondary)
                            }
                            .padding(12)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func automaticRemoteModelSection(
        for providerID: APIProviderID,
        snapshot: APIProviderConfigurationSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("模型")
                .font(.subheadline.weight(.semibold))

            configurationMetric(
                title: "当前模型",
                value: snapshot.reasoningModel.title,
                tint: .blue
            )

            if store.supportsRemoteModelDiscovery(for: providerID) {
                Button {
                    store.refreshRemoteModels(for: providerID)
                } label: {
                    HStack(spacing: 8) {
                        if store.isFetchingRemoteModels(for: providerID) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text(store.isFetchingRemoteModels(for: providerID) ? "检测中" : "检测模型")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.isFetchingRemoteModels(for: providerID))
            }
        }
    }

    private func capsuleLabel(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private func apiKeyBinding(for providerID: APIProviderID) -> Binding<String> {
        Binding(
            get: { store.apiKeyDraft(for: providerID) },
            set: { store.setAPIKeyDraft($0, for: providerID) }
        )
    }

    private func accessModeBinding(for providerID: APIProviderID) -> Binding<APIAccessModeID> {
        Binding(
            get: { store.selectedAccessModeID(for: providerID) },
            set: { store.setSelectedAccessModeID($0, for: providerID) }
        )
    }

    private func modelBinding(for providerID: APIProviderID) -> Binding<String> {
        Binding(
            get: { store.selectedModelID(for: providerID) },
            set: { store.setSelectedModelID($0, for: providerID) }
        )
    }

    private func customBaseURLBinding(for providerID: APIProviderID) -> Binding<String> {
        Binding(
            get: { store.customBaseURLDraft(for: providerID) },
            set: { store.setCustomBaseURLDraft($0, for: providerID) }
        )
    }

    private var activeProviderBinding: Binding<APIProviderID> {
        Binding(
            get: { store.activeProviderID },
            set: { store.setActiveProviderID($0) }
        )
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.09, blue: 0.16),
                Color(red: 0.09, green: 0.20, blue: 0.29),
                Color(red: 0.12, green: 0.13, blue: 0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Circle()
                .fill(.teal.opacity(0.20))
                .blur(radius: 120)
                .offset(x: -140, y: -240)
            Circle()
                .fill(.cyan.opacity(0.16))
                .blur(radius: 140)
                .offset(x: 160, y: 320)
        }
        .ignoresSafeArea()
    }
}
