import Foundation

enum ReasoningReplayPolicy: String, Codable, Sendable {
    case none
    case preserveForToolHistory
    case preserveWhenReturned
}

enum LLMReasoningControlKind: String, Codable, Sendable {
    case none
    case openAIReasoningEffort
    case thinkingSwitch
    case qwenThinkingBudget
    case minimaxReasoningSplit
    case stepfunReasoningFormat
    case openRouterReasoning
}

enum ProviderCapabilitySource: String, Codable, Sendable {
    case curatedOfficialDocs
    case remoteModelList
    case localRuntime
    case customUserInput
    case conservativeUnknown
}

struct LLMModelUIControls: Codable, Sendable, Hashable {
    let reasoning: LLMReasoningControlKind
    let allowsVisionInput: Bool
    let allowsToolCalling: Bool
    let allowsJSONMode: Bool

    static let basicText = LLMModelUIControls(
        reasoning: .none,
        allowsVisionInput: false,
        allowsToolCalling: false,
        allowsJSONMode: false
    )

    static func from(capabilities: LLMModelCapabilities) -> LLMModelUIControls {
        let reasoning: LLMReasoningControlKind
        switch capabilities.nativeReasoning {
        case .unsupported:
            reasoning = .none
        case .openAIReasoningEffort:
            reasoning = .openAIReasoningEffort
        case .thinkingSwitch, .thinkingSwitchWithEffort, .glmThinking, .enableThinking, .deepSeekThinkingEffort, .kimiThinking:
            reasoning = .thinkingSwitch
        case .qwenThinkingBudget:
            reasoning = .qwenThinkingBudget
        case .minimaxReasoningSplit:
            reasoning = .minimaxReasoningSplit
        case .stepfunReasoningFormat:
            reasoning = .stepfunReasoningFormat
        case .openRouterReasoning:
            reasoning = .openRouterReasoning
        }
        return LLMModelUIControls(
            reasoning: reasoning,
            allowsVisionInput: capabilities.supportsVision,
            allowsToolCalling: capabilities.supportsToolCalls,
            allowsJSONMode: capabilities.supportsJSONMode
        )
    }
}

struct LLMEndpointSpec: Codable, Sendable, Hashable {
    let chatCompletionsPath: String

    static let openAICompatibleChat = LLMEndpointSpec(chatCompletionsPath: "chat/completions")
}

struct LLMRequestEncodingSpec: Codable, Sendable, Hashable {
    let omitsSamplingParametersWhenThinking: Bool
    let notes: String
}

struct LLMResponseDecodingSpec: Codable, Sendable, Hashable {
    let reasoningContentField: String?
    let reasoningDetailsField: String?
}

struct LLMModelValidationPlan: Codable, Sendable, Hashable {
    let requiresChatSnapshot: Bool
    let requiresStreamSnapshot: Bool
    let requiresToolReplaySnapshot: Bool
    let requiresVisionSnapshot: Bool
}

struct LLMModelIntegrationSpec: Codable, Sendable, Hashable {
    let providerID: APIProviderID
    let modelID: String
    let modelFamily: String
    let officialDocs: [URL]
    let endpoint: LLMEndpointSpec
    let requestEncoding: LLMRequestEncodingSpec
    let responseDecoding: LLMResponseDecodingSpec
    let capabilities: LLMModelCapabilities
    let reasoningReplayPolicy: ReasoningReplayPolicy
    let uiControls: LLMModelUIControls
    let validationPlan: LLMModelValidationPlan
    let capabilitySource: ProviderCapabilitySource
    let isCurated: Bool
}

enum LLMModelIntegrationCatalog {
    static func spec(for providerID: APIProviderID, modelID: String) -> LLMModelIntegrationSpec {
        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return exactSpecs[key(providerID: providerID, modelID: trimmedID)] ??
        inferredSpec(providerID: providerID, modelID: trimmedID, traits: []) ??
        unknownOpenAICompatibleSpec(providerID: providerID, modelID: trimmedID, traits: [])
    }

    static func spec(for providerID: APIProviderID, model: APIModelDefinition) -> LLMModelIntegrationSpec {
        let trimmedModel = APIModelDefinition(
            id: model.id.trimmingCharacters(in: .whitespacesAndNewlines),
            title: model.title,
            summary: model.summary,
            traits: model.traits
        )
        return exactSpecs[key(providerID: providerID, modelID: trimmedModel.id)] ??
        inferredSpec(providerID: providerID, modelID: trimmedModel.id, traits: trimmedModel.traits) ??
        unknownOpenAICompatibleSpec(providerID: providerID, modelID: trimmedModel.id, traits: trimmedModel.traits)
    }

    static func isCurated(providerID: APIProviderID, modelID: String) -> Bool {
        let trimmedID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return exactSpecs[key(providerID: providerID, modelID: trimmedID)] != nil
    }

    static func canonicalModel(for providerID: APIProviderID, model: APIModelDefinition) -> APIModelDefinition {
        let canonicalID = canonicalModelID(for: providerID, modelID: model.id)
        guard canonicalID != model.id else {
            return model
        }
        switch (providerID, canonicalID) {
        case (.deepseek, "deepseek-v4-flash"):
            return APIModelDefinition(
                id: canonicalID,
                title: "DeepSeek V4 Flash",
                summary: "",
                traits: [.lightweight]
            )
        case (.deepseek, "deepseek-v4-pro"):
            return APIModelDefinition(
                id: canonicalID,
                title: "DeepSeek V4 Pro",
                summary: "",
                traits: []
            )
        default:
            return APIModelDefinition(
                id: canonicalID,
                title: canonicalID,
                summary: model.summary,
                traits: model.traits
            )
        }
    }

    static func canonicalModelID(for providerID: APIProviderID, modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        switch providerID {
        case .deepseek:
            switch lowercased {
            case "deepseek-chat", "deepseek-v3", "deepseek-v3.1", "deepseek-v3.2":
                return "deepseek-v4-flash"
            case "deepseek-reasoner", "deepseek-r1":
                return "deepseek-v4-pro"
            default:
                return trimmed
            }
        default:
            return trimmed
        }
    }

    private static let exactSpecs: [String: LLMModelIntegrationSpec] = {
        var specs: [String: LLMModelIntegrationSpec] = [:]
        func register(_ spec: LLMModelIntegrationSpec) {
            specs[key(providerID: spec.providerID, modelID: spec.modelID)] = spec
        }

        registerMany(.openai, [
            text("gpt-4.1", family: "openai-gpt-4.1", docs: openAIDocs, vision: true, tools: true),
            text("gpt-4.1-mini", family: "openai-gpt-4.1", docs: openAIDocs, vision: true, tools: true),
            openAIReasoning("gpt-5.4", family: "openai-gpt-5", vision: true),
            openAIReasoning("gpt-5.4-mini", family: "openai-gpt-5", vision: true),
            openAIReasoning("o4-mini", family: "openai-o", vision: true),
            openAIReasoning("o3", family: "openai-o", vision: true)
        ], register)

        registerMany(.azureOpenAI, [
            openAIReasoning("gpt-5.4", family: "azure-openai-deployment", vision: true, docs: azureDocs),
            text("gpt-4.1", family: "azure-openai-deployment", docs: azureDocs, vision: true, tools: true)
        ], register)

        registerMany(.glm, [
            glm("glm-5.1"),
            glm("glm-5-turbo"),
            glm("glm-5"),
            glm("glm-5v-turbo", vision: true),
            glm("glm-4.7"),
            glm("glm-4.7-flash"),
            glm("glm-4.7-flashx"),
            glm("glm-4.6"),
            glm("glm-4.5"),
            glm("glm-4.5-air"),
            glm("glm-4.5-airx"),
            glm("glm-4.5-flash")
        ], register)

        registerMany(.deepseek, [
            deepSeek("deepseek-v4-flash", tools: true, thinkingDefault: false),
            deepSeek("deepseek-v4-pro", tools: true, thinkingDefault: true)
        ], register)

        registerMany(.qwen, [
            text("qwen-max", family: "qwen-text", docs: qwenDocs, tools: true),
            text("qwen-plus", family: "qwen-text", docs: qwenDocs, tools: true),
            text("qwen-turbo", family: "qwen-text", docs: qwenDocs, tools: true),
            qwenThinking("qwen3-max"),
            qwenThinking("qwen3-coder-plus"),
            qwenThinking("qwen3.6-plus", vision: true),
            qwenThinking("qwen3-vl-plus", defaultEnabled: false, vision: true),
            qwenThinking("qwen3-vl-max", defaultEnabled: false, vision: true)
        ], register)

        registerMany(.kimi, [
            kimi("kimi-k2.5", vision: true),
            kimi("kimi-k2-thinking", vision: false),
            kimi("kimi-k2.6", vision: true),
            text("kimi-k2-turbo-preview", family: "kimi-k2", docs: kimiDocs, tools: true),
            text("moonshot-v1-128k", family: "moonshot-v1", docs: kimiDocs, tools: true),
            text("moonshot-v1-128k-vision-preview", family: "moonshot-v1-vision", docs: kimiDocs, vision: true, tools: true)
        ], register)

        registerMany(.minimax, [
            minimax("MiniMax-M2.7"),
            minimax("MiniMax-M2.7-highspeed"),
            minimax("MiniMax-M2.5"),
            minimax("MiniMax-M2.5-highspeed"),
            text("MiniMax-Text-01", family: "minimax-text", docs: minimaxDocs, tools: true)
        ], register)

        registerMany(.volcengine, [
            doubao("doubao-seed-1-6"),
            doubao("doubao-seed-1-6-thinking"),
            doubao("doubao-seed-1-6-flash"),
            doubao("doubao-seed-1-6-vision-250815", vision: true)
        ], register)

        registerMany(.hunyuan, [
            text("hunyuan-turbos-latest", family: "hunyuan-turbos", docs: hunyuanDocs, tools: true),
            text("hunyuan-large", family: "hunyuan-large", docs: hunyuanDocs, tools: true),
            text("hunyuan-t1-vision-20250916", family: "hunyuan-t1-vision", docs: hunyuanDocs, vision: true, tools: true),
            text("hunyuan-vision-1.5-instruct", family: "hunyuan-vision", docs: hunyuanDocs, vision: true, tools: true)
        ], register)

        registerMany(.qianfan, [
            text("ernie-4.5-turbo-128k", family: "ernie-4.5", docs: qianfanDocs, tools: true),
            fixedReasoning("ernie-x1-turbo-32k", providerID: .qianfan, family: "qianfan-ernie-x1", docs: qianfanDocs),
            text("ernie-4.5-turbo-vl", family: "ernie-4.5-vl", docs: qianfanDocs, vision: true, tools: true),
            text("ernie-4.5-turbo-vl-preview", family: "ernie-4.5-vl", docs: qianfanDocs, vision: true, tools: true),
            enableThinking("ernie-4.5-vl-28b-a3b", providerID: .qianfan, family: "qianfan-ernie-vl-thinking", docs: qianfanDocs, defaultEnabled: false, vision: true),
            qwenThinking("qwen3-vl-32b-instruct", providerID: .qianfan, defaultEnabled: false, vision: true, docs: qianfanDocs)
        ], register)

        registerMany(.stepfun, [
            stepfunReasoning("step-3.5-flash-2603", vision: false),
            stepfunReasoning("step-3.5-flash", vision: false),
            stepfunReasoning("step-1o-turbo-vision", vision: true),
            stepfunReasoning("step-1v-8k", vision: true)
        ], register)

        registerMany(.modelscope, [
            qwenThinking("Qwen/Qwen3-Coder-Plus", providerID: .modelscope, docs: modelscopeDocs),
            text("Qwen/Qwen2.5-VL-72B-Instruct", providerID: .modelscope, family: "qwen-vl", docs: modelscopeDocs, vision: true, tools: true),
            text("Qwen/Qwen2.5-VL-32B-Instruct", providerID: .modelscope, family: "qwen-vl", docs: modelscopeDocs, vision: true, tools: true)
        ], register)

        registerMany(.siliconflow, [
            siliconFlowReasoning("deepseek-ai/DeepSeek-V3.2"),
            siliconFlowReasoning("Qwen/Qwen3-Coder-480B-A35B-Instruct"),
            siliconFlowReasoning("moonshotai/Kimi-K2-Instruct"),
            text("Qwen/Qwen2.5-VL-72B-Instruct", providerID: .siliconflow, family: "qwen-vl", docs: siliconFlowDocs, vision: true, tools: true),
            text("Qwen/Qwen2-VL-72B-Instruct", providerID: .siliconflow, family: "qwen-vl", docs: siliconFlowDocs, vision: true, tools: true)
        ], register)

        registerMany(.openrouter, [
            openRouter("openai/gpt-5.4", family: "openrouter-openai", vision: true),
            text("openai/gpt-4.1", providerID: .openrouter, family: "openrouter-openai", docs: openRouterDocs, vision: true, tools: true),
            openRouter("anthropic/claude-sonnet-4.5", family: "openrouter-anthropic", vision: true),
            text("google/gemini-2.5-flash", providerID: .openrouter, family: "openrouter-gemini", docs: openRouterDocs, vision: true, tools: true),
            openRouter("deepseek/deepseek-v3.2", family: "openrouter-deepseek", vision: false)
        ], register)

        registerMany(.lmstudio, [
            unknownLocal("lmstudio-auto", providerID: .lmstudio)
        ], register)

        registerMany(.ollama, [
            unknownLocal("llama3.3", providerID: .ollama),
            unknownLocal("qwen3", providerID: .ollama),
            unknownLocal("deepseek-r1", providerID: .ollama),
            unknownLocal("qwen2.5vl", providerID: .ollama, vision: true),
            unknownLocal("llava", providerID: .ollama, vision: true)
        ], register)

        registerMany(.customOpenAI, [
            unknownOpenAICompatibleSpec(providerID: .customOpenAI, modelID: "gpt-4.1", traits: []),
            openAIReasoning("gpt-5.4", family: "custom-openai-reasoning", vision: false, docs: customDocs, providerID: .customOpenAI)
        ], register)

        return specs
    }()

    private static func inferredSpec(
        providerID: APIProviderID,
        modelID: String,
        traits: Set<APIModelTrait>
    ) -> LLMModelIntegrationSpec? {
        let lowercasedID = modelID.lowercased()
        let vision = traits.contains(.multimodal) || isVisionModelID(lowercasedID)
        let source: ProviderCapabilitySource = providerID == .customOpenAI ? .customUserInput : .remoteModelList

        switch providerID {
        case .openrouter:
            if isReasoningModelID(lowercasedID) {
                return inferred(openRouter(modelID, family: "openrouter-inferred", vision: vision), source: source)
            }
            return nil

        case .qwen:
            if isQwenThinkingModelID(lowercasedID) {
                return inferred(qwenThinking(modelID, providerID: .qwen, defaultEnabled: !isQwenVisionModelID(lowercasedID), vision: vision, docs: qwenDocs), source: source)
            }
            if isKimiThinkingModelID(lowercasedID) {
                return inferred(enableThinking(modelID, providerID: .qwen, family: "dashscope-kimi-thinking", docs: qwenDocs, defaultEnabled: true, vision: vision, defaultBudget: 8_192), source: source)
            }
            if isDashScopeEnableThinkingModelID(lowercasedID) {
                return inferred(enableThinking(modelID, providerID: .qwen, family: "dashscope-thinking", docs: qwenDocs, defaultEnabled: true, vision: vision), source: source)
            }
            return nil

        case .siliconflow:
            if isSiliconFlowReasoningModelID(lowercasedID) {
                return inferred(siliconFlowReasoning(modelID, vision: vision), source: source)
            }
            if isMiniMaxModelID(lowercasedID) {
                return inferred(fixedReasoning(modelID, providerID: .siliconflow, family: "siliconflow-minimax-reasoning", docs: siliconFlowDocs, vision: vision), source: source)
            }
            return nil

        case .qianfan:
            if isQwenThinkingModelID(lowercasedID) {
                return inferred(qwenThinking(modelID, providerID: .qianfan, defaultEnabled: !isQwenVisionModelID(lowercasedID), vision: vision, docs: qianfanDocs), source: source)
            }
            if lowercasedID.contains("ernie-5.0-thinking") || lowercasedID.contains("ernie-4.5-vl") {
                return inferred(enableThinking(modelID, providerID: .qianfan, family: "qianfan-enable-thinking", docs: qianfanDocs, defaultEnabled: lowercasedID.contains("thinking"), vision: vision), source: source)
            }
            if lowercasedID.contains("ernie-x1") || lowercasedID.contains("deepseek-r1") {
                return inferred(fixedReasoning(modelID, providerID: .qianfan, family: "qianfan-fixed-reasoning", docs: qianfanDocs, vision: vision), source: source)
            }
            return nil

        case .modelscope:
            if isQwenThinkingModelID(lowercasedID) {
                return inferred(qwenThinking(modelID, providerID: .modelscope, defaultEnabled: !isQwenVisionModelID(lowercasedID), vision: vision, docs: modelscopeDocs), source: source)
            }
            return nil

        case .deepseek:
            if isDeepSeekModelID(lowercasedID) {
                return inferred(
                    deepSeek(
                        modelID,
                        providerID: .deepseek,
                        tools: deepSeekSupportsTools(lowercasedID),
                        thinkingDefault: !lowercasedID.contains("flash")
                    ),
                    source: source
                )
            }
            return nil

        case .glm:
            if isGLMModelID(lowercasedID) {
                return inferred(glm(modelID, providerID: .glm, vision: vision), source: source)
            }
            return nil

        case .kimi:
            if isKimiThinkingModelID(lowercasedID) {
                return inferred(kimi(modelID, providerID: .kimi, vision: vision, docs: kimiDocs), source: source)
            }
            return nil

        case .minimax:
            if isMiniMaxModelID(lowercasedID) {
                return inferred(minimax(modelID, providerID: .minimax, docs: minimaxDocs), source: source)
            }
            return nil

        case .volcengine:
            if isDoubaoModelID(lowercasedID) {
                return inferred(doubao(modelID, providerID: .volcengine, vision: vision, docs: volcengineDocs), source: source)
            }
            return nil

        case .stepfun:
            if lowercasedID.hasPrefix("step-") {
                return inferred(stepfunReasoning(modelID, providerID: .stepfun, vision: vision, docs: stepfunDocs), source: source)
            }
            return nil

        case .hunyuan:
            if lowercasedID.contains("hy3-preview") {
                return inferred(
                    tokenHubThinkingEffort(
                        modelID,
                        family: "hunyuan-tokenhub-hy3",
                        defaultEnabled: false,
                        defaultEffort: .low,
                        vision: vision
                    ),
                    source: source
                )
            }
            if lowercasedID.contains("deepseek-v4") || lowercasedID.contains("deepseek-v3.2") {
                return inferred(
                    tokenHubThinkingEffort(
                        modelID,
                        family: "hunyuan-tokenhub-deepseek",
                        defaultEnabled: !lowercasedID.contains("v3.2"),
                        defaultEffort: .high,
                        vision: vision
                    ),
                    source: source
                )
            }
            if lowercasedID.contains("hunyuan-2.0-thinking") ||
                lowercasedID.contains("minimax-m2.7") ||
                lowercasedID.contains("minimax-m2.5") {
                return inferred(
                    fixedReasoning(
                        modelID,
                        providerID: .hunyuan,
                        family: "hunyuan-tokenhub-fixed-reasoning",
                        docs: hunyuanTokenHubDocs,
                        vision: vision
                    ),
                    source: source
                )
            }
            if isGLMModelID(lowercasedID) || isKimiThinkingModelID(lowercasedID) {
                return inferred(
                    tokenHubThinkingSwitch(
                        modelID,
                        family: "hunyuan-tokenhub-thinking-switch",
                        defaultEnabled: true,
                        vision: vision
                    ),
                    source: source
                )
            }
            return nil

        case .openai, .azureOpenAI, .customOpenAI:
            if isOpenAIReasoningModelID(lowercasedID) {
                return inferred(
                    openAIReasoning(
                        modelID,
                        family: "openai-reasoning",
                        vision: vision || lowercasedID.hasPrefix("gpt-"),
                        docs: providerID == .azureOpenAI ? azureDocs : openAIDocs,
                        providerID: providerID
                    ),
                    source: source
                )
            }
            return nil

        case .lmstudio, .ollama:
            return inferred(unknownLocal(modelID, providerID: providerID, vision: vision), source: .localRuntime)
        }
    }

    private static func inferred(
        _ spec: LLMModelIntegrationSpec,
        source: ProviderCapabilitySource
    ) -> LLMModelIntegrationSpec {
        spec.replacingCapabilitySource(source, isCurated: false)
    }

    private static func key(providerID: APIProviderID, modelID: String) -> String {
        "\(providerID.rawValue)::\(modelID.lowercased())"
    }

    private static func registerMany(
        _ providerID: APIProviderID,
        _ specs: [LLMModelIntegrationSpec],
        _ register: (LLMModelIntegrationSpec) -> Void
    ) {
        for spec in specs {
            register(spec.replacingProviderID(providerID))
        }
    }

    private static func text(
        _ modelID: String,
        providerID: APIProviderID? = nil,
        family: String,
        docs: [URL],
        vision: Bool = false,
        tools: Bool = true
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: providerID,
            modelID: modelID,
            family: family,
            docs: docs,
            capabilities: capabilities(vision: vision, tools: tools)
        )
    }

    private static func openAIReasoning(
        _ modelID: String,
        family: String,
        vision: Bool,
        docs: [URL] = openAIDocs,
        providerID: APIProviderID = .openai
    ) -> LLMModelIntegrationSpec {
        let levels = openAIReasoningLevels(for: modelID)
        return make(
            providerID: providerID,
            modelID: modelID,
            family: family,
            docs: docs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                nativeReasoning: .openAIReasoningEffort(levels: levels, defaultLevel: .medium)
            )
        )
    }

    private static func openAIReasoningLevels(for modelID: String) -> Set<LLMReasoningEffort> {
        let lowercasedID = modelID.lowercased()
        if lowercasedID.hasPrefix("gpt-5.4") ||
            lowercasedID.hasPrefix("gpt-5.3") ||
            lowercasedID.hasPrefix("gpt-5.2") ||
            lowercasedID.hasPrefix("gpt-5.1-codex-max") {
            return [.minimal, .low, .medium, .high, .xhigh]
        }

        return [.minimal, .low, .medium, .high]
    }

    private static func glm(
        _ modelID: String,
        providerID: APIProviderID = .glm,
        vision: Bool = false,
        docs: [URL] = glmDocs
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: providerID,
            modelID: modelID,
            family: "glm",
            docs: docs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                replay: true,
                nativeReasoning: .glmThinking(defaultEnabled: true)
            ),
            replayPolicy: .preserveWhenReturned,
            responseDecoding: response(reasoningContent: "reasoning_content")
        )
    }

    private static func deepSeek(
        _ modelID: String,
        providerID: APIProviderID = .deepseek,
        tools: Bool,
        requiredToolChoice: Bool = true,
        thinkingDefault: Bool,
        docs: [URL] = deepSeekDocs
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: providerID,
            modelID: modelID,
            family: "deepseek",
            docs: docs,
            requestEncoding: .init(omitsSamplingParametersWhenThinking: true, notes: "DeepSeek thinking mode ignores standard sampling parameters."),
            capabilities: capabilities(
                vision: false,
                tools: tools,
                requiredToolChoice: tools && requiredToolChoice,
                replay: true,
                nativeReasoning: .deepSeekThinkingEffort(defaultEnabled: thinkingDefault)
            ),
            replayPolicy: .preserveForToolHistory,
            responseDecoding: response(reasoningContent: "reasoning_content")
        )
    }

    private static func qwenThinking(
        _ modelID: String,
        providerID: APIProviderID = .qwen,
        defaultEnabled: Bool = true,
        vision: Bool = false,
        docs: [URL] = qwenDocs
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: providerID,
            modelID: modelID,
            family: "qwen-thinking",
            docs: docs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                replay: true,
                nativeReasoning: .qwenThinkingBudget(defaultEnabled: defaultEnabled, defaultBudget: nil)
            ),
            replayPolicy: .preserveWhenReturned,
            responseDecoding: response(reasoningContent: "reasoning_content")
        )
    }

    private static func kimi(
        _ modelID: String,
        providerID: APIProviderID = .kimi,
        vision: Bool,
        docs: [URL] = kimiDocs
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: providerID,
            modelID: modelID,
            family: "kimi-thinking",
            docs: docs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                requiredToolChoice: false,
                replay: true,
                nativeReasoning: .kimiThinking(defaultEnabled: true)
            ),
            replayPolicy: .preserveForToolHistory,
            responseDecoding: response(reasoningContent: "reasoning_content")
        )
    }

    private static func minimax(
        _ modelID: String,
        providerID: APIProviderID = .minimax,
        docs: [URL] = minimaxDocs
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: providerID,
            modelID: modelID,
            family: "minimax-m2",
            docs: docs,
            capabilities: capabilities(
                tools: true,
                replay: true,
                nativeReasoning: .minimaxReasoningSplit
            ),
            replayPolicy: .preserveWhenReturned,
            responseDecoding: response(reasoningDetails: "reasoning_details")
        )
    }

    private static func fixedReasoning(
        _ modelID: String,
        providerID: APIProviderID,
        family: String,
        docs: [URL],
        vision: Bool = false
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: providerID,
            modelID: modelID,
            family: family,
            docs: docs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                replay: true
            ),
            replayPolicy: .preserveWhenReturned,
            responseDecoding: response(reasoningContent: "reasoning_content")
        )
    }

    private static func enableThinking(
        _ modelID: String,
        providerID: APIProviderID,
        family: String,
        docs: [URL],
        defaultEnabled: Bool,
        vision: Bool = false,
        defaultBudget: Int? = nil
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: providerID,
            modelID: modelID,
            family: family,
            docs: docs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                replay: true,
                nativeReasoning: defaultBudget == nil
                    ? .enableThinking(defaultEnabled: defaultEnabled)
                    : .qwenThinkingBudget(defaultEnabled: defaultEnabled, defaultBudget: defaultBudget)
            ),
            replayPolicy: .preserveWhenReturned,
            responseDecoding: response(reasoningContent: "reasoning_content")
        )
    }

    private static func tokenHubThinkingSwitch(
        _ modelID: String,
        family: String,
        defaultEnabled: Bool,
        vision: Bool = false
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: .hunyuan,
            modelID: modelID,
            family: family,
            docs: hunyuanTokenHubDocs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                replay: true,
                nativeReasoning: .thinkingSwitch(defaultEnabled: defaultEnabled)
            ),
            replayPolicy: .preserveWhenReturned,
            responseDecoding: response(reasoningContent: "reasoning_content")
        )
    }

    private static func tokenHubThinkingEffort(
        _ modelID: String,
        family: String,
        defaultEnabled: Bool,
        defaultEffort: LLMReasoningEffort,
        vision: Bool = false
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: .hunyuan,
            modelID: modelID,
            family: family,
            docs: hunyuanTokenHubDocs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                replay: true,
                nativeReasoning: .thinkingSwitchWithEffort(
                    defaultEnabled: defaultEnabled,
                    levels: [.low, .medium, .high],
                    defaultLevel: defaultEffort
                )
            ),
            replayPolicy: .preserveWhenReturned,
            responseDecoding: response(reasoningContent: "reasoning_content")
        )
    }

    private static func doubao(
        _ modelID: String,
        providerID: APIProviderID = .volcengine,
        vision: Bool = false,
        docs: [URL] = volcengineDocs
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: providerID,
            modelID: modelID,
            family: "doubao-seed",
            docs: docs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                replay: true,
                nativeReasoning: .thinkingSwitch(defaultEnabled: true)
            ),
            replayPolicy: .preserveWhenReturned,
            responseDecoding: response(reasoningContent: "reasoning_content")
        )
    }

    private static func stepfunReasoning(
        _ modelID: String,
        providerID: APIProviderID = .stepfun,
        vision: Bool,
        docs: [URL] = stepfunDocs
    ) -> LLMModelIntegrationSpec {
        make(
            providerID: providerID,
            modelID: modelID,
            family: "stepfun-reasoning",
            docs: docs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                nativeReasoning: .stepfunReasoningFormat(defaultFormat: "general")
            ),
            responseDecoding: response(reasoningContent: "reasoning")
        )
    }

    private static func siliconFlowReasoning(
        _ modelID: String,
        vision: Bool = false
    ) -> LLMModelIntegrationSpec {
        enableThinking(
            modelID,
            providerID: .siliconflow,
            family: "siliconflow-reasoning",
            docs: siliconFlowDocs,
            defaultEnabled: true,
            vision: vision,
            defaultBudget: 4_096
        )
    }

    private static func openRouter(_ modelID: String, family: String, vision: Bool) -> LLMModelIntegrationSpec {
        make(
            providerID: .openrouter,
            modelID: modelID,
            family: family,
            docs: openRouterDocs,
            capabilities: capabilities(
                vision: vision,
                tools: true,
                nativeReasoning: .openRouterReasoning(defaultLevel: .medium)
            )
        )
    }

    private static func unknownLocal(
        _ modelID: String,
        providerID: APIProviderID,
        vision: Bool = false
    ) -> LLMModelIntegrationSpec {
        var capabilities = LLMModelCapabilities.localUnknown
        capabilities.supportsVision = vision
        return make(
            providerID: providerID,
            modelID: modelID,
            family: "local-unknown",
            docs: providerID == .ollama ? ollamaDocs : lmStudioDocs,
            capabilities: capabilities,
            uiControls: .from(capabilities: capabilities),
            capabilitySource: .localRuntime,
            isCurated: true
        )
    }

    private static func unknownOpenAICompatibleSpec(
        providerID: APIProviderID,
        modelID: String,
        traits: Set<APIModelTrait>
    ) -> LLMModelIntegrationSpec {
        var capabilities = LLMModelCapabilities.basicText
        capabilities.supportsVision = traits.contains(.multimodal)
        return make(
            providerID: providerID,
            modelID: modelID,
            family: "unknown-openai-compatible",
            docs: customDocs,
            capabilities: capabilities,
            uiControls: .from(capabilities: capabilities),
            capabilitySource: traits.isEmpty ? .conservativeUnknown : .remoteModelList,
            isCurated: false
        )
    }

    private static func make(
        providerID: APIProviderID?,
        modelID: String,
        family: String,
        docs: [URL],
        requestEncoding: LLMRequestEncodingSpec = .init(omitsSamplingParametersWhenThinking: false, notes: ""),
        capabilities: LLMModelCapabilities,
        replayPolicy: ReasoningReplayPolicy = .none,
        responseDecoding: LLMResponseDecodingSpec = response(),
        uiControls: LLMModelUIControls? = nil,
        capabilitySource: ProviderCapabilitySource? = nil,
        isCurated: Bool = true
    ) -> LLMModelIntegrationSpec {
        let resolvedProviderID = providerID ?? .openai
        return LLMModelIntegrationSpec(
            providerID: resolvedProviderID,
            modelID: modelID,
            modelFamily: family,
            officialDocs: docs,
            endpoint: .openAICompatibleChat,
            requestEncoding: requestEncoding,
            responseDecoding: responseDecoding,
            capabilities: capabilities,
            reasoningReplayPolicy: replayPolicy,
            uiControls: uiControls ?? .from(capabilities: capabilities),
            validationPlan: validationPlan(for: capabilities),
            capabilitySource: capabilitySource ?? (isCurated ? .curatedOfficialDocs : .conservativeUnknown),
            isCurated: isCurated
        )
    }

    private static func capabilities(
        vision: Bool = false,
        tools: Bool = true,
        requiredToolChoice: Bool? = nil,
        json: Bool = true,
        streaming: Bool = true,
        replay: Bool = false,
        nativeReasoning: LLMNativeReasoningEncoding = .unsupported
    ) -> LLMModelCapabilities {
        let resolvedRequiredToolChoice = requiredToolChoice ?? tools
        return LLMModelCapabilities(
            supportsToolCalls: tools,
            supportsRequiredToolChoice: tools && resolvedRequiredToolChoice,
            supportsVision: vision,
            supportsJSONMode: json,
            supportsStreaming: streaming,
            supportsReasoningReplay: replay,
            nativeReasoning: nativeReasoning
        )
    }

    private static func response(
        reasoningContent: String? = nil,
        reasoningDetails: String? = nil
    ) -> LLMResponseDecodingSpec {
        LLMResponseDecodingSpec(
            reasoningContentField: reasoningContent,
            reasoningDetailsField: reasoningDetails
        )
    }

    private static func validationPlan(for capabilities: LLMModelCapabilities) -> LLMModelValidationPlan {
        LLMModelValidationPlan(
            requiresChatSnapshot: true,
            requiresStreamSnapshot: capabilities.supportsStreaming,
            requiresToolReplaySnapshot: capabilities.supportsToolCalls && capabilities.supportsReasoningReplay,
            requiresVisionSnapshot: capabilities.supportsVision
        )
    }

    private static func isVisionModelID(_ lowercasedID: String) -> Bool {
        [
            "vision",
            "visual",
            "vl",
            "omni",
            "multimodal",
            "image",
            "5v",
            "4.5v",
            "4.6v"
        ].contains { signal in
            lowercasedID.contains(signal)
        }
    }

    private static func isReasoningModelID(_ lowercasedID: String) -> Bool {
        [
            "reason",
            "thinking",
            "think",
            "gpt-5",
            "o3",
            "o4",
            "qwen3",
            "qwq",
            "deepseek",
            "glm-5",
            "glm-4.7",
            "glm-4.6",
            "glm-4.5",
            "kimi-k2",
            "minimax-m2",
            "ernie-x1",
            "hunyuan-t1"
        ].contains { signal in
            lowercasedID.contains(signal)
        }
    }

    private static func isOpenAIReasoningModelID(_ lowercasedID: String) -> Bool {
        lowercasedID.hasPrefix("gpt-5") ||
        lowercasedID.hasPrefix("o1") ||
        lowercasedID.hasPrefix("o3") ||
        lowercasedID.hasPrefix("o4")
    }

    private static func isQwenThinkingModelID(_ lowercasedID: String) -> Bool {
        lowercasedID.contains("qwen3") ||
        lowercasedID.contains("qwq") ||
        lowercasedID.contains("qwen3.5") ||
        lowercasedID.contains("qwen3.6")
    }

    private static func isQwenVisionModelID(_ lowercasedID: String) -> Bool {
        lowercasedID.contains("qwen3-vl") ||
        lowercasedID.contains("qwen3vl") ||
        lowercasedID.contains("qwen3.5") ||
        lowercasedID.contains("qwen3.6")
    }

    private static func isKimiThinkingModelID(_ lowercasedID: String) -> Bool {
        lowercasedID.contains("kimi-k2.5") ||
        lowercasedID.contains("kimi-k2-thinking") ||
        lowercasedID.contains("kimi-k2.6")
    }

    private static func isDashScopeEnableThinkingModelID(_ lowercasedID: String) -> Bool {
        lowercasedID.contains("deepseek-v3.2") ||
        lowercasedID.contains("deepseek-r1") ||
        lowercasedID.contains("thinking")
    }

    private static func isSiliconFlowReasoningModelID(_ lowercasedID: String) -> Bool {
        lowercasedID.contains("qwen/qwen3") ||
        lowercasedID.contains("qwen/qwq") ||
        lowercasedID.contains("deepseek-ai/deepseek-v3.1") ||
        lowercasedID.contains("deepseek-ai/deepseek-v3.2") ||
        lowercasedID.contains("tencent/hunyuan-a13b") ||
        lowercasedID.contains("zai-org/glm-5v") ||
        lowercasedID.contains("zai-org/glm-4.6v") ||
        lowercasedID.contains("zai-org/glm-4.5v")
    }

    private static func isDeepSeekModelID(_ lowercasedID: String) -> Bool {
        lowercasedID.contains("deepseek")
    }

    private static func deepSeekSupportsTools(_ lowercasedID: String) -> Bool {
        !(lowercasedID.contains("reasoner") ||
          lowercasedID.contains("r1"))
    }

    private static func isGLMModelID(_ lowercasedID: String) -> Bool {
        lowercasedID.contains("glm-5") ||
        lowercasedID.contains("glm-4.7") ||
        lowercasedID.contains("glm-4.6") ||
        lowercasedID.contains("glm-4.5")
    }

    private static func isMiniMaxModelID(_ lowercasedID: String) -> Bool {
        lowercasedID.contains("minimax-m2")
    }

    private static func isDoubaoModelID(_ lowercasedID: String) -> Bool {
        lowercasedID.contains("doubao-seed") || lowercasedID.contains("doubao-1.5")
    }

    private static func docs(_ urls: String...) -> [URL] {
        urls.compactMap(URL.init(string:))
    }

    private static let openAIDocs = docs(
        "https://platform.openai.com/docs/api-reference/chat/create-chat-completion",
        "https://platform.openai.com/docs/guides/reasoning",
        "https://platform.openai.com/docs/models"
    )
    private static let azureDocs = docs(
        "https://learn.microsoft.com/en-us/azure/ai-services/openai/reference",
        "https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/reasoning"
    )
    private static let glmDocs = docs(
        "https://docs.z.ai/guides/capabilities/thinking-mode",
        "https://docs.z.ai/guides/capabilities/thinking",
        "https://docs.z.ai/api-reference/llm/chat-completion"
    )
    private static let deepSeekDocs = docs(
        "https://api-docs.deepseek.com/guides/thinking_mode",
        "https://api-docs.deepseek.com"
    )
    private static let qwenDocs = docs(
        "https://docs.qwencloud.com/api-reference/toolkitframework/openai-compatible/overview",
        "https://docs.qwencloud.com/developer-guides/text-generation/thinking",
        "https://www.alibabacloud.com/help/en/model-studio/deep-thinking",
        "https://qwen.readthedocs.io/en/stable/getting_started/quickstart.html"
    )
    private static let kimiDocs = docs(
        "https://platform.moonshot.ai/docs/overview",
        "https://platform.moonshot.ai/docs/guide/use-kimi-k2-thinking-model.en-US"
    )
    private static let minimaxDocs = docs("https://platform.minimax.io/docs/api-reference/text-m2-function-call-refer")
    private static let volcengineDocs = docs(
        "https://www.volcengine.com/docs/82379/1298454",
        "https://www.volcengine.com/docs/6492/2192012"
    )
    private static let hunyuanDocs = docs("https://cloud.tencent.com/document/product/1729/111007")
    private static let hunyuanTokenHubDocs = docs(
        "https://cloud.tencent.com/document/product/1823/131208",
        "https://cloud.tencent.com/document/product/1772/115968"
    )
    private static let qianfanDocs = docs(
        "https://cloud.baidu.com/doc/qianfan-docs/s/Wm95lyynv",
        "https://cloud.baidu.com/doc/qianfan-docs/s/7m95lyy43",
        "https://cloud.baidu.com/doc/qianfan-docs/s/xm95lyys5"
    )
    private static let stepfunDocs = docs(
        "https://platform.stepfun.ai/docs/en/api-reference/chat/chat-completion-create",
        "https://platform.stepfun.ai/docs/en/step-plan/integrations/reasoning-api",
        "https://platform.stepfun.ai/docs/en/guides/developer/reasoning",
        "https://platform.stepfun.ai/docs/en/llm/modeloverview"
    )
    private static let modelscopeDocs = docs("https://modelscope.cn/docs/model-service/API-Inference/intro")
    private static let siliconFlowDocs = docs(
        "https://docs.siliconflow.com/en/api-reference/chat-completions/chat-completions_copy",
        "https://docs.siliconflow.com/llms.txt"
    )
    private static let openRouterDocs = docs(
        "https://openrouter.ai/docs/api-reference/chat-completion",
        "https://openrouter.ai/docs/api-reference/overview",
        "https://openrouter.ai/docs/api/reference/responses/reasoning",
        "https://openrouter.ai/docs/guides/best-practices/reasoning-tokens"
    )
    private static let lmStudioDocs = docs(
        "https://lmstudio.ai/docs/developer/rest",
        "https://lmstudio.ai/docs/app/api/tools",
        "https://lmstudio.ai/docs/developer/openai-compat/chat-completions"
    )
    private static let ollamaDocs = docs(
        "https://docs.ollama.com/openai",
        "https://docs.ollama.com/capabilities/thinking",
        "https://docs.ollama.com/api",
        "https://docs.ollama.com/api/chat"
    )
    private static let customDocs = docs("https://platform.openai.com/docs/api-reference/chat/create-chat-completion")
}

private extension LLMModelIntegrationSpec {
    func replacingProviderID(_ providerID: APIProviderID) -> LLMModelIntegrationSpec {
        LLMModelIntegrationSpec(
            providerID: providerID,
            modelID: modelID,
            modelFamily: modelFamily,
            officialDocs: officialDocs,
            endpoint: endpoint,
            requestEncoding: requestEncoding,
            responseDecoding: responseDecoding,
            capabilities: capabilities,
            reasoningReplayPolicy: reasoningReplayPolicy,
            uiControls: uiControls,
            validationPlan: validationPlan,
            capabilitySource: capabilitySource,
            isCurated: isCurated
        )
    }

    func replacingCapabilitySource(
        _ source: ProviderCapabilitySource,
        isCurated: Bool
    ) -> LLMModelIntegrationSpec {
        LLMModelIntegrationSpec(
            providerID: providerID,
            modelID: modelID,
            modelFamily: modelFamily,
            officialDocs: officialDocs,
            endpoint: endpoint,
            requestEncoding: requestEncoding,
            responseDecoding: responseDecoding,
            capabilities: capabilities,
            reasoningReplayPolicy: reasoningReplayPolicy,
            uiControls: uiControls,
            validationPlan: validationPlan,
            capabilitySource: source,
            isCurated: isCurated
        )
    }
}
