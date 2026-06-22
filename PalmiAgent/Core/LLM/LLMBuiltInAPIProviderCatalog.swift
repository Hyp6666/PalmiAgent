import Foundation

enum LLMBuiltInAPIProviderCatalog {
    static let additionalProviders: [APIProviderDefinition] = [
        officialProvider(
            id: .openai,
            title: "OpenAI",
            subtitle: "官方 OpenAI-compatible 接入。第一阶段使用 Chat Completions；Responses API 后续单独适配。",
            baseURL: "https://api.openai.com/v1",
            models: [
                model("gpt-5.4", "GPT-5.4", "强推理主模型。", [.reasoningPreferred, .multimodal]),
                model("gpt-5.4-mini", "GPT-5.4 Mini", "轻量高频模型。", [.lightweight, .multimodal]),
                model("gpt-4.1", "GPT-4.1", "稳定通用模型。", [.multimodal]),
                model("gpt-4.1-mini", "GPT-4.1 Mini", "轻量通用模型。", [.lightweight, .multimodal]),
                model("o4-mini", "o4-mini", "OpenAI o 系列轻量推理模型。", [.reasoningPreferred, .lightweight, .multimodal]),
                model("o3", "o3", "OpenAI o 系列推理模型。", [.reasoningPreferred, .multimodal])
            ]
        ),
        profileManagedProvider(
            id: .azureOpenAI,
            title: "Azure OpenAI",
            subtitle: "Azure 官方 OpenAI 服务。需要填写 Azure OpenAI 的完整 OpenAI-compatible endpoint。",
            placeholder: "请输入 Azure OpenAI API Key",
            endpointPlaceholder: "https://<resource>.openai.azure.com/openai/deployments/<deployment>",
            categoryNote: "Azure endpoint 与 api-version 常按资源和部署配置变化；如需 query 参数可先使用完整 URL 或自定义来源。",
            models: [
                model("gpt-5.4", "GPT-5.4", "Azure 常用推理模型。", [.reasoningPreferred, .multimodal]),
                model("gpt-4.1", "GPT-4.1", "Azure 常用通用模型。", [.multimodal])
            ]
        ),
        officialProvider(
            id: .qwen,
            title: "通义千问",
            subtitle: "阿里云百炼 / DashScope OpenAI-compatible 接入。",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            models: [
                model("qwen-max", "Qwen Max", "通用旗舰模型。", [.reasoningPreferred]),
                model("qwen-plus", "Qwen Plus", "通用均衡模型。"),
                model("qwen-turbo", "Qwen Turbo", "轻量高频模型。", [.lightweight]),
                model("qwen3-max", "Qwen3 Max", "Qwen3 系列推理候选。", [.reasoningPreferred]),
                model("qwen3-coder-plus", "Qwen3 Coder Plus", "编码与 Agent 任务候选。", [.reasoningPreferred]),
                model("qwen3.6-plus", "Qwen3.6 Plus", "Qwen3.6 视觉理解候选。", [.multimodal]),
                model("qwen3-vl-plus", "Qwen3 VL Plus", "Qwen3 视觉理解候选。", [.multimodal]),
                model("qwen3-vl-max", "Qwen3 VL Max", "Qwen3 视觉理解旗舰候选。", [.multimodal])
            ]
        ),
        officialProvider(
            id: .kimi,
            title: "Kimi",
            subtitle: "Moonshot AI 官方 OpenAI-compatible 接入。",
            baseURL: "https://api.moonshot.cn/v1",
            models: [
                model("kimi-k2.5", "Kimi K2.5", "Kimi thinking-capable 主模型。", [.reasoningPreferred, .multimodal]),
                model("kimi-k2-thinking", "Kimi K2 Thinking", "Kimi thinking 专用模型。", [.reasoningPreferred]),
                model("kimi-k2.6", "Kimi K2.6", "Kimi K 系列主模型。", [.reasoningPreferred, .multimodal]),
                model("kimi-k2-turbo-preview", "Kimi K2 Turbo Preview", "偏速度的 Kimi K 系列候选。", [.lightweight]),
                model("moonshot-v1-128k", "Moonshot v1 128K", "长上下文通用模型。"),
                model("moonshot-v1-128k-vision-preview", "Moonshot v1 128K Vision", "Moonshot 视觉理解候选。", [.multimodal])
            ]
        ),
        officialProvider(
            id: .minimax,
            title: "MiniMax",
            subtitle: "MiniMax 官方 OpenAI-compatible 接入。",
            baseURL: "https://api.minimax.io/v1",
            models: [
                model("MiniMax-M2.7", "MiniMax M2.7", "MiniMax 主力 Agent/推理候选。", [.reasoningPreferred]),
                model("MiniMax-M2.7-highspeed", "MiniMax M2.7 Highspeed", "MiniMax M2.7 高速候选。", [.reasoningPreferred, .lightweight]),
                model("MiniMax-M2.5", "MiniMax M2.5", "MiniMax M2.5 推理候选。", [.reasoningPreferred]),
                model("MiniMax-M2.5-highspeed", "MiniMax M2.5 Highspeed", "MiniMax M2.5 高速候选。", [.reasoningPreferred, .lightweight]),
                model("MiniMax-Text-01", "MiniMax Text 01", "通用文本模型。")
            ]
        ),
        officialProvider(
            id: .volcengine,
            title: "火山方舟",
            subtitle: "火山引擎方舟 OpenAI-compatible 接入，模型 ID 通常为用户自己的 endpoint/model 标识。",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            models: [
                model("doubao-seed-1-6", "Doubao Seed 1.6", "豆包主力模型候选。"),
                model("doubao-seed-1-6-thinking", "Doubao Seed 1.6 Thinking", "豆包推理候选。", [.reasoningPreferred]),
                model("doubao-seed-1-6-flash", "Doubao Seed 1.6 Flash", "轻量高频候选。", [.lightweight]),
                model("doubao-seed-1-6-vision-250815", "Doubao Seed 1.6 Vision", "豆包视觉理解候选。", [.multimodal])
            ]
        ),
        officialProvider(
            id: .hunyuan,
            title: "腾讯混元",
            subtitle: "腾讯混元 OpenAI-compatible 接入。",
            baseURL: "https://api.hunyuan.cloud.tencent.com/v1",
            models: [
                model("hunyuan-turbos-latest", "Hunyuan Turbos Latest", "混元通用模型候选。"),
                model("hunyuan-large", "Hunyuan Large", "混元大模型候选。", [.reasoningPreferred]),
                model("hunyuan-t1-vision-20250916", "Hunyuan T1 Vision", "混元视觉推理候选。", [.reasoningPreferred, .multimodal]),
                model("hunyuan-vision-1.5-instruct", "Hunyuan Vision 1.5", "混元图生文候选。", [.multimodal])
            ]
        ),
        officialProvider(
            id: .qianfan,
            title: "百度千帆",
            subtitle: "百度智能云千帆 OpenAI-compatible 接入。",
            baseURL: "https://qianfan.baidubce.com/v2",
            models: [
                model("ernie-4.5-turbo-128k", "ERNIE 4.5 Turbo 128K", "文心主力通用模型候选。"),
                model("ernie-x1-turbo-32k", "ERNIE X1 Turbo 32K", "推理模型候选。", [.reasoningPreferred, .lightweight]),
                model("ernie-4.5-turbo-vl", "ERNIE 4.5 Turbo VL", "文心视觉理解候选。", [.multimodal]),
                model("ernie-4.5-turbo-vl-preview", "ERNIE 4.5 Turbo VL Preview", "文心视觉理解预览候选。", [.multimodal]),
                model("ernie-4.5-vl-28b-a3b", "ERNIE 4.5 VL", "文心视觉候选。", [.multimodal]),
                model("qwen3-vl-32b-instruct", "Qwen3 VL 32B", "千帆托管视觉候选。", [.multimodal])
            ]
        ),
        officialProvider(
            id: .stepfun,
            title: "阶跃星辰",
            subtitle: "StepFun 官方 OpenAI-compatible 接入。",
            baseURL: "https://api.stepfun.com/v1",
            models: [
                model("step-3.5-flash-2603", "Step 3.5 Flash 2603", "Step 3.5 Flash 候选。", [.lightweight]),
                model("step-3.5-flash", "Step 3.5 Flash", "轻量通用候选。", [.lightweight]),
                model("step-1o-turbo-vision", "Step 1O Turbo Vision", "Step 视觉理解候选。", [.multimodal]),
                model("step-1v-8k", "Step 1V 8K", "Step 视觉候选。", [.multimodal])
            ]
        ),
        profileManagedProvider(
            id: .modelscope,
            title: "ModelScope",
            subtitle: "魔搭社区 / ModelScope OpenAI-compatible 接入。不同模型服务 endpoint 可能不同。",
            placeholder: "ModelScope API Key",
            endpointPlaceholder: "https://api-inference.modelscope.cn/v1",
            categoryNote: "",
            models: [
                model("Qwen/Qwen3-Coder-Plus", "Qwen3 Coder Plus", "ModelScope 上的 Qwen 编码模型候选。", [.reasoningPreferred]),
                model("Qwen/Qwen2.5-VL-72B-Instruct", "Qwen2.5 VL 72B", "ModelScope 托管视觉候选。", [.multimodal]),
                model("Qwen/Qwen2.5-VL-32B-Instruct", "Qwen2.5 VL 32B", "ModelScope 托管视觉候选。", [.multimodal])
            ]
        ),
        officialProvider(
            id: .siliconflow,
            title: "SiliconFlow",
            subtitle: "硅基流动 OpenAI-compatible 接入，适合国内主流开源/商业模型聚合。",
            baseURL: "https://api.siliconflow.cn/v1",
            models: [
                model("deepseek-ai/DeepSeek-V3.2", "DeepSeek V3.2", "硅基流动上的 DeepSeek 候选。", [.reasoningPreferred]),
                model("Qwen/Qwen3-Coder-480B-A35B-Instruct", "Qwen3 Coder 480B", "编码与 Agent 候选。", [.reasoningPreferred]),
                model("moonshotai/Kimi-K2-Instruct", "Kimi K2 Instruct", "Kimi 开源/托管候选。", [.reasoningPreferred]),
                model("Qwen/Qwen2.5-VL-72B-Instruct", "Qwen2.5 VL 72B", "硅基流动视觉候选。", [.multimodal]),
                model("Qwen/Qwen2-VL-72B-Instruct", "Qwen2 VL 72B", "硅基流动视觉候选。", [.multimodal])
            ]
        ),
        officialProvider(
            id: .openrouter,
            title: "OpenRouter",
            subtitle: "全球主流模型聚合平台。Palmi 只按 OpenAI-compatible 方式接入，用户自行确认服务与数据合规。",
            baseURL: "https://openrouter.ai/api/v1",
            models: [
                model("openai/gpt-5.4", "OpenAI GPT-5.4", "OpenRouter 上的 OpenAI 候选。", [.reasoningPreferred, .multimodal]),
                model("openai/gpt-4.1", "OpenAI GPT-4.1", "OpenRouter 上的 OpenAI 视觉候选。", [.multimodal]),
                model("anthropic/claude-sonnet-4.5", "Claude Sonnet 4.5", "经 OpenRouter OpenAI-compatible 调用。", [.reasoningPreferred, .multimodal]),
                model("google/gemini-2.5-flash", "Gemini 2.5 Flash", "OpenRouter 上的 Gemini 视觉候选。", [.lightweight, .multimodal]),
                model("deepseek/deepseek-v3.2", "DeepSeek V3.2", "DeepSeek 候选。", [.reasoningPreferred])
            ]
        ),
        profileManagedProvider(
            id: .ollama,
            title: "Ollama",
            subtitle: "本地 Ollama OpenAI-compatible `/v1` 接入。",
            placeholder: "API Key",
            endpointPlaceholder: "http://localhost:11434/v1",
            secretRequirement: .optional,
            categoryNote: "只接 Ollama 的 OpenAI-compatible `/v1`，不接原生 `/api/generate`。",
            models: [
                model("llama3.3", "Llama 3.3", "本地通用候选。"),
                model("qwen3", "Qwen3", "本地 Qwen3 候选。", [.reasoningPreferred]),
                model("deepseek-r1", "DeepSeek R1", "本地推理候选。", [.reasoningPreferred]),
                model("qwen2.5vl", "Qwen2.5 VL", "Ollama 本地视觉候选。", [.multimodal]),
                model("llava", "LLaVA", "Ollama 本地视觉候选。", [.multimodal])
            ]
        ),
        profileManagedProvider(
            id: .customOpenAI,
            title: "自定义 OpenAI-compatible",
            subtitle: "接入用户自己的 OpenAI-compatible 服务。Palmi 不背书具体供应商。",
            placeholder: "API Key",
            endpointPlaceholder: "https://api.example.com/v1",
            secretRequirement: .optional,
            categoryNote: "",
            // 不预置任何模型：模型名由用户手动填写（只要走 OpenAI 兼容协议即可）。
            models: [],
            editableModelRoles: [.reasoningModel]
        )
    ]

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
            placeholder: "请输入 \(title) API Key",
            secretRequirement: .required,
            endpointStrategy: .catalogManaged,
            modelSelectionStyle: .catalog,
            editableModelRoles: editableRoles(for: models),
            transport: .openAICompatibleChatCompletions,
            accessModes: [
                APIAccessModeDefinition(
                    id: .standardAPI,
                    title: "标准 API",
                    subtitle: "官方或主流 OpenAI-compatible API。",
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
                    title: "自定义端点",
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
