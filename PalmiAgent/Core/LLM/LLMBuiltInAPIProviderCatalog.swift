import Foundation

enum LLMBuiltInAPIProviderCatalog {
    static var additionalProviders: [APIProviderDefinition] {
        [
        officialProvider(
            id: .openai,
            title: "OpenAI",
            subtitle: text("provider.openai.subtitle"),
            baseURL: "https://api.openai.com/v1",
            models: [
                model("gpt-5.4", "GPT-5.4", summary("reasoningPrimary"), [.reasoningPreferred, .multimodal]),
                model("gpt-5.4-mini", "GPT-5.4 Mini", summary("lightweightFrequent"), [.lightweight, .multimodal]),
                model("gpt-4.1", "GPT-4.1", summary("stableGeneral"), [.multimodal]),
                model("gpt-4.1-mini", "GPT-4.1 Mini", summary("lightweightGeneral"), [.lightweight, .multimodal]),
                model("o4-mini", "o4-mini", summary("openaiLightReasoning"), [.reasoningPreferred, .lightweight, .multimodal]),
                model("o3", "o3", summary("openaiReasoning"), [.reasoningPreferred, .multimodal])
            ]
        ),
        profileManagedProvider(
            id: .azureOpenAI,
            title: "Azure OpenAI",
            subtitle: text("provider.azureOpenAI.subtitle"),
            placeholder: text("provider.azureOpenAI.placeholder"),
            endpointPlaceholder: "https://<resource>.openai.azure.com/openai/deployments/<deployment>",
            categoryNote: text("provider.azureOpenAI.note"),
            models: [
                model("gpt-5.4", "GPT-5.4", summary("azureReasoning"), [.reasoningPreferred, .multimodal]),
                model("gpt-4.1", "GPT-4.1", summary("azureGeneral"), [.multimodal])
            ]
        ),
        officialProvider(
            id: .qwen,
            title: text("provider.qwen.title"),
            subtitle: text("provider.qwen.subtitle"),
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            models: [
                model("qwen-max", "Qwen Max", summary("generalFlagship"), [.reasoningPreferred]),
                model("qwen-plus", "Qwen Plus", summary("generalBalanced")),
                model("qwen-turbo", "Qwen Turbo", summary("lightweightFrequent"), [.lightweight]),
                model("qwen3-max", "Qwen3 Max", summary("qwenReasoning"), [.reasoningPreferred]),
                model("qwen3-coder-plus", "Qwen3 Coder Plus", summary("codingAgentCandidate"), [.reasoningPreferred]),
                model("qwen3.6-plus", "Qwen3.6 Plus", summary("qwenVision"), [.multimodal]),
                model("qwen3-vl-plus", "Qwen3 VL Plus", summary("qwenVision"), [.multimodal]),
                model("qwen3-vl-max", "Qwen3 VL Max", summary("qwenVisionFlagship"), [.multimodal])
            ]
        ),
        officialProvider(
            id: .kimi,
            title: "Kimi",
            subtitle: text("provider.kimi.subtitle"),
            baseURL: "https://api.moonshot.cn/v1",
            models: [
                model("kimi-k2.5", "Kimi K2.5", summary("kimiThinkingPrimary"), [.reasoningPreferred, .multimodal]),
                model("kimi-k2-thinking", "Kimi K2 Thinking", summary("kimiThinkingDedicated"), [.reasoningPreferred]),
                model("kimi-k2.6", "Kimi K2.6", summary("kimiPrimary"), [.reasoningPreferred, .multimodal]),
                model("kimi-k2-turbo-preview", "Kimi K2 Turbo Preview", summary("speedFocusedCandidate"), [.lightweight]),
                model("moonshot-v1-128k", "Moonshot v1 128K", summary("longContextGeneral")),
                model("moonshot-v1-128k-vision-preview", "Moonshot v1 128K Vision", summary("moonshotVision"), [.multimodal])
            ]
        ),
        officialProvider(
            id: .minimax,
            title: "MiniMax",
            subtitle: text("provider.minimax.subtitle"),
            baseURL: "https://api.minimax.io/v1",
            models: [
                model("MiniMax-M2.7", "MiniMax M2.7", summary("minimaxAgentReasoning"), [.reasoningPreferred]),
                model("MiniMax-M2.7-highspeed", "MiniMax M2.7 Highspeed", summary("minimaxHighspeed"), [.reasoningPreferred, .lightweight]),
                model("MiniMax-M2.5", "MiniMax M2.5", summary("minimaxReasoning"), [.reasoningPreferred]),
                model("MiniMax-M2.5-highspeed", "MiniMax M2.5 Highspeed", summary("minimaxHighspeed"), [.reasoningPreferred, .lightweight]),
                model("MiniMax-Text-01", "MiniMax Text 01", summary("generalText"))
            ]
        ),
        officialProvider(
            id: .volcengine,
            title: text("provider.volcengine.title"),
            subtitle: text("provider.volcengine.subtitle"),
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            models: [
                model("doubao-seed-1-6", "Doubao Seed 1.6", summary("primaryCandidate")),
                model("doubao-seed-1-6-thinking", "Doubao Seed 1.6 Thinking", summary("reasoningCandidate"), [.reasoningPreferred]),
                model("doubao-seed-1-6-flash", "Doubao Seed 1.6 Flash", summary("lightweightFrequent"), [.lightweight]),
                model("doubao-seed-1-6-vision-250815", "Doubao Seed 1.6 Vision", summary("visionCandidate"), [.multimodal])
            ]
        ),
        officialProvider(
            id: .hunyuan,
            title: text("provider.hunyuan.title"),
            subtitle: text("provider.hunyuan.subtitle"),
            baseURL: "https://api.hunyuan.cloud.tencent.com/v1",
            models: [
                model("hunyuan-turbos-latest", "Hunyuan Turbos Latest", summary("generalCandidate")),
                model("hunyuan-large", "Hunyuan Large", summary("largeCandidate"), [.reasoningPreferred]),
                model("hunyuan-t1-vision-20250916", "Hunyuan T1 Vision", summary("visionReasoningCandidate"), [.reasoningPreferred, .multimodal]),
                model("hunyuan-vision-1.5-instruct", "Hunyuan Vision 1.5", summary("imageToTextCandidate"), [.multimodal])
            ]
        ),
        officialProvider(
            id: .qianfan,
            title: text("provider.qianfan.title"),
            subtitle: text("provider.qianfan.subtitle"),
            baseURL: "https://qianfan.baidubce.com/v2",
            models: [
                model("ernie-4.5-turbo-128k", "ERNIE 4.5 Turbo 128K", summary("primaryGeneralCandidate")),
                model("ernie-x1-turbo-32k", "ERNIE X1 Turbo 32K", summary("reasoningCandidate"), [.reasoningPreferred, .lightweight]),
                model("ernie-4.5-turbo-vl", "ERNIE 4.5 Turbo VL", summary("visionCandidate"), [.multimodal]),
                model("ernie-4.5-turbo-vl-preview", "ERNIE 4.5 Turbo VL Preview", summary("visionPreviewCandidate"), [.multimodal]),
                model("ernie-4.5-vl-28b-a3b", "ERNIE 4.5 VL", summary("visionCandidate"), [.multimodal]),
                model("qwen3-vl-32b-instruct", "Qwen3 VL 32B", summary("hostedVisionCandidate"), [.multimodal])
            ]
        ),
        officialProvider(
            id: .stepfun,
            title: text("provider.stepfun.title"),
            subtitle: text("provider.stepfun.subtitle"),
            baseURL: "https://api.stepfun.com/v1",
            models: [
                model("step-3.5-flash-2603", "Step 3.5 Flash 2603", summary("flashCandidate"), [.lightweight]),
                model("step-3.5-flash", "Step 3.5 Flash", summary("lightweightGeneral"), [.lightweight]),
                model("step-1o-turbo-vision", "Step 1O Turbo Vision", summary("visionCandidate"), [.multimodal]),
                model("step-1v-8k", "Step 1V 8K", summary("visionCandidate"), [.multimodal])
            ]
        ),
        profileManagedProvider(
            id: .modelscope,
            title: "ModelScope",
            subtitle: text("provider.modelscope.subtitle"),
            placeholder: "ModelScope API Key",
            endpointPlaceholder: "https://api-inference.modelscope.cn/v1",
            categoryNote: "",
            models: [
                model("Qwen/Qwen3-Coder-Plus", "Qwen3 Coder Plus", summary("hostedCodingCandidate"), [.reasoningPreferred]),
                model("Qwen/Qwen2.5-VL-72B-Instruct", "Qwen2.5 VL 72B", summary("hostedVisionCandidate"), [.multimodal]),
                model("Qwen/Qwen2.5-VL-32B-Instruct", "Qwen2.5 VL 32B", summary("hostedVisionCandidate"), [.multimodal])
            ]
        ),
        officialProvider(
            id: .siliconflow,
            title: "SiliconFlow",
            subtitle: text("provider.siliconflow.subtitle"),
            baseURL: "https://api.siliconflow.cn/v1",
            models: [
                model("deepseek-ai/DeepSeek-V3.2", "DeepSeek V3.2", summary("hostedDeepSeekCandidate"), [.reasoningPreferred]),
                model("Qwen/Qwen3-Coder-480B-A35B-Instruct", "Qwen3 Coder 480B", summary("codingAgentCandidate"), [.reasoningPreferred]),
                model("moonshotai/Kimi-K2-Instruct", "Kimi K2 Instruct", summary("hostedOpenSourceCandidate"), [.reasoningPreferred]),
                model("Qwen/Qwen2.5-VL-72B-Instruct", "Qwen2.5 VL 72B", summary("hostedVisionCandidate"), [.multimodal]),
                model("Qwen/Qwen2-VL-72B-Instruct", "Qwen2 VL 72B", summary("hostedVisionCandidate"), [.multimodal])
            ]
        ),
        officialProvider(
            id: .openrouter,
            title: "OpenRouter",
            subtitle: text("provider.openrouter.subtitle"),
            baseURL: "https://openrouter.ai/api/v1",
            models: [
                model("openai/gpt-5.4", "OpenAI GPT-5.4", summary("openrouterOpenAICandidate"), [.reasoningPreferred, .multimodal]),
                model("openai/gpt-4.1", "OpenAI GPT-4.1", summary("openrouterOpenAIVision"), [.multimodal]),
                model("anthropic/claude-sonnet-4.5", "Claude Sonnet 4.5", summary("openrouterCompatible"), [.reasoningPreferred, .multimodal]),
                model("google/gemini-2.5-flash", "Gemini 2.5 Flash", summary("openrouterGeminiVision"), [.lightweight, .multimodal]),
                model("deepseek/deepseek-v3.2", "DeepSeek V3.2", summary("deepseekCandidate"), [.reasoningPreferred])
            ]
        ),
        profileManagedProvider(
            id: .ollama,
            title: "Ollama",
            subtitle: text("provider.ollama.subtitle"),
            placeholder: "API Key",
            endpointPlaceholder: "http://localhost:11434/v1",
            secretRequirement: .optional,
            categoryNote: text("provider.ollama.note"),
            models: [
                model("llama3.3", "Llama 3.3", summary("localGeneral")),
                model("qwen3", "Qwen3", summary("localQwen"), [.reasoningPreferred]),
                model("deepseek-r1", "DeepSeek R1", summary("localReasoning"), [.reasoningPreferred]),
                model("qwen2.5vl", "Qwen2.5 VL", summary("localVision"), [.multimodal]),
                model("llava", "LLaVA", summary("localVision"), [.multimodal])
            ]
        ),
        profileManagedProvider(
            id: .customOpenAI,
            title: text("provider.customOpenAI.title"),
            subtitle: text("provider.customOpenAI.subtitle"),
            placeholder: "API Key",
            endpointPlaceholder: "https://api.example.com/v1",
            secretRequirement: .optional,
            categoryNote: "",
            // 不预置任何模型：模型名由用户手动填写（只要走 OpenAI 兼容协议即可）。
            models: [],
            editableModelRoles: [.reasoningModel]
        )
        ]
    }

    private static func text(_ key: String) -> String {
        PalmiL10n.tr("llm.builtin.\(key)")
    }

    private static func summary(_ key: String) -> String {
        PalmiL10n.tr("llm.model.summary.\(key)")
    }

    private static func officialProvider(
        id: APIProviderID,
        title: String,
        subtitle: String,
        baseURL: String,
        models: [APIModelDefinition]
    ) -> APIProviderDefinition {
        APIProviderDefinition(
            id: id,
            title: title,
            subtitle: subtitle,
            secretLabel: "API Key",
            placeholder: PalmiL10n.tr("llm.builtin.placeholder.apiKeyFormat", title),
            secretRequirement: .required,
            endpointStrategy: .catalogManaged,
            modelSelectionStyle: .catalog,
            editableModelRoles: editableRoles(for: models),
            transport: .openAICompatibleChatCompletions,
            accessModes: [
                APIAccessModeDefinition(
                    id: .standardAPI,
                    title: text("access.standard.title"),
                    subtitle: text("access.standard.subtitle"),
                    badgeText: "OpenAI-compatible",
                    baseURL: URL(string: baseURL)!,
                    models: models,
                    note: ""
                )
            ],
            preferredAccessModeID: .standardAPI,
            supportsServerDiscovery: false
        )
    }

    private static func profileManagedProvider(
        id: APIProviderID,
        title: String,
        subtitle: String,
        placeholder: String,
        endpointPlaceholder: String,
        secretRequirement: APISecretRequirement = .required,
        categoryNote: String,
        models: [APIModelDefinition],
        editableModelRoles: [APIModelRole]? = nil
    ) -> APIProviderDefinition {
        APIProviderDefinition(
            id: id,
            title: title,
            subtitle: subtitle,
            secretLabel: "API Key",
            placeholder: placeholder,
            secretRequirement: secretRequirement,
            endpointStrategy: .profileManaged,
            modelSelectionStyle: .catalog,
            editableModelRoles: editableModelRoles ?? editableRoles(for: models),
            transport: .openAICompatibleChatCompletions,
            accessModes: [
                APIAccessModeDefinition(
                    id: .standardAPI,
                    title: text("access.customEndpoint.title"),
                    subtitle: endpointPlaceholder,
                    badgeText: "OpenAI-compatible",
                    baseURL: nil,
                    models: models,
                    note: categoryNote
                )
            ],
            preferredAccessModeID: .standardAPI,
            supportsServerDiscovery: false
        )
    }

    private static func model(
        _ id: String,
        _ title: String,
        _ summary: String,
        _ traits: Set<APIModelTrait> = []
    ) -> APIModelDefinition {
        APIModelDefinition(id: id, title: title, summary: summary, traits: traits)
    }

    private static func editableRoles(for models: [APIModelDefinition]) -> [APIModelRole] {
        var roles: [APIModelRole] = [.reasoningModel, .multimodalModel]
        if models.contains(where: { $0.traits.contains(.lightweight) }) {
            roles.append(.lightweightModel)
        }
        return roles
    }
}
