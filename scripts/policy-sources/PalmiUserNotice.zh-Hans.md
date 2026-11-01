# Palmi 用户知情与第三方 AI 服务提示

版本：v26.11　　版本日期：2026.11.01

请在配置模型前完整阅读本文件。点击「我已阅读并同意」仅表示你理解并确认本文件所列的数据流向、第三方服务边界、敏感信息注意事项和用户选择责任；它不表示你已经同意任何未展示的第三方条款。第三方服务的正式政策以其当前页面为准。

## 1. 阅读性质和适用范围

本文件是 Palmi在首次模型配置前向用户展示的「用户知情与第三方 AI 服务提示」。它用于说明本机应用、用户自选模型服务、系统权限和第三方工具之间可能发生的数据流向，并要求用户在继续配置模型前作出明确确认。

本文件不是某一家模型厂商的隐私政策，也不替代任何第三方模型服务商、云厂商、模型聚合平台、企业网关、系统服务或本地部署服务的服务协议、隐私政策、开发者协议、数据处理协议、可接受使用政策、模型许可或安全规则。

Palmi 是一个本机优先的 Agent 应用和模型接入界面。用户选择哪个模型、填写哪个 Base URL、使用哪个 API Key、发送哪些内容、是否打开系统权限和工具能力，都会影响数据是否离开本机以及由谁处理。

## 2. 当前产品设计下的本机数据处理

在当前版本设计中，Palmi 不以自有服务器作为集中式聊天内容、工作区文件、附件或 API Key 数据库。项目、会话、工作区文件、附件、运行记录、缓存和偏好设置主要保存在设备本机应用容器内；模型凭据应保存于系统 Keychain 或同等安全凭据存储。

本机 OCR、文件预览、工作区读写、嵌入式 Python、局部缓存、会话管理和数据清理等能力通常在设备本机执行。只要用户没有配置远程模型、远程搜索、远程文件服务、云同步、分享导出或其他第三方功能，相应内容通常不会因 Palmi 自身而被发送至 Palmi 运营的远程服务器。

设备系统、iCloud/系统备份、崩溃诊断、App Store、企业移动设备管理、网络代理、VPN、安全软件和用户主动导出的文件，可能按照 Apple、组织管理员、网络服务商或用户选择的第三方规则处理数据。Palmi 无法控制这些系统级或用户主动选择的处理。

## 3. 哪些情况下数据可能离开本机

当用户配置并使用远程模型服务、模型聚合平台、云厂商托管 endpoint、企业网关或自定义 OpenAI-compatible endpoint 时，发送给模型的提示词、上下文、文件摘要、图片、工具结果、模型角色配置、系统指令片段、对话历史、错误信息和必要请求元数据可能被发送至对应服务。

当用户启用网页搜索、网页读取、地图、邮件、消息、电话、日历、提醒事项、通讯录、位置、相机、照片、语音识别、通知、Spotlight、系统路由或其他工具能力时，相关内容可能由对应系统服务、第三方搜索源、网站、账户服务、企业环境或网络服务处理。

当用户导入、打开、复制、分享、导出、发送、上传或让 Agent 对文件执行外部动作时，相应文件或其中内容可能被写入用户选择的位置、传给用户选择的应用、服务商或联系人，或进入对应系统的缓存和日志。

请求传输通常需要网络连接。网络运营商、DNS、代理、VPN、网关、防火墙、企业安全产品或第三方 SDK/服务可能按照其自身规则处理网络元数据。

## 4. 模型服务、OpenAI-compatible endpoint 和责任边界

OpenAI-compatible 仅说明某个接口在路径、鉴权方式、请求格式、消息结构、流式响应或工具调用形态上与 OpenAI 生态相似。它不表示该服务由 OpenAI 提供，不表示其安全水平、数据留存、训练使用、删除机制、跨境传输、争议解决或适用法律与 OpenAI 相同。

第三方模型服务、云厂商、模型聚合平台、企业网关和自部署服务可能分别充当独立个人信息处理者、受托处理者、共同处理者、基础设施提供方或模型托管方。它们如何记录日志、留存输入输出、用于安全审查、用于模型训练、转交上游模型、处理删除请求或应对监管请求，以其当前有效政策和用户账户协议为准。

Palmi 无法代表用户验证用户填写的 endpoint 归属、API Key 来源、账号权限、服务区域、账单责任、数据保留期限、模型训练设置、零数据保留配置、企业数据保护条款或上游模型实际处理方。用户在使用前应自行确认。

## 5. 敏感内容、企业资料和他人数据

用户不应在没有充分授权、合法依据和安全评估的情况下，向模型或工具提交密码、API Key、私钥、身份号码、银行卡、医疗健康资料、未成年人信息、精确位置、通讯录、聊天记录、客户资料、源代码机密、商业秘密、未公开研究、受保密协议保护的内容、受监管数据或任何可能导致他人权益受损的资料。

如果用户代表公司、学校、实验室、项目组、客户、家庭成员或其他第三方使用 Palmi，用户应确认自己有权配置模型服务、发送相关内容、授予系统权限、调用工具、上传或导出文件，并应遵守所在组织的数据分类、保密、合规、采购和安全审批要求。

如果无法确定某类信息是否可以发送给模型或第三方服务，应默认不要发送，或先进行脱敏、摘要、匿名化、本机处理、内部审批或选择满足相应合规要求的企业服务。

## 6. 工具调用、系统权限和外部动作

Palmi 的 Agent 能力可能建议或触发读取文件、生成文件、修改工作区、调用网页搜索、读取日历/提醒事项/通讯录/位置/照片/相机/语音、打开系统应用、生成消息草稿或执行其他系统动作。不同工具可能需要 iOS 系统权限、用户确认、第三方账号授权或组织策略允许。

任何会影响外部系统、他人、账户资产、时间安排、文件状态、消息发送、购买、支付、部署、删除或公开披露的动作，用户都应在执行前进行人工复核。模型输出可能不完整、不准确、过时、虚构、带有偏见，或误解用户意图。

如果用户启用自动批准、批量执行、脚本执行、网页自动化、系统路由或企业工具集成，风险会显著增加。用户应只对可信任务和可回滚环境启用此类能力。

## 7. 本机数据管理、撤回和删除

用户可以通过应用内数据管理、系统设置、iOS 权限管理、Keychain/凭据重置、模型服务商控制台、第三方账号后台、组织管理员、云厂商工单或卸载应用等方式管理本机数据和第三方账号数据。

清理 Palmi 本机工作区、缓存、偏好设置或模型凭据，只影响设备本机或 Palmi 保存的副本；这不会自动删除已经发送至第三方模型服务、搜索源、网站、云厂商、聚合平台、企业网关、系统服务或其他应用的数据。第三方侧数据的访问、更正、导出、删除、停止训练、关闭记忆或关闭日志留存，应按照对应服务商的政策和账号工具办理。

删除或卸载应用可能仍受到系统备份、企业设备管理、日志、导出文件、共享副本、第三方留存期限和法律保留义务影响。

## 8. AI 输出和专业风险提示

模型输出不构成法律、医疗、金融、投资、税务、工程安全、心理健康、就业、移民、教育升学或其他专业意见。对于高风险或专业场景，用户应咨询合格专业人员并进行独立验证。

模型可能生成错误事实、错误代码、错误引用、误导性安全建议、不可执行方案、过期政策、虚假链接或不适当内容。用户应对使用、传播、执行、提交或依赖模型输出所产生的后果进行审慎判断。

Palmi 是工具和工作流界面，不保证任何第三方模型、endpoint、工具、搜索源、系统服务或用户配置始终可用、准确、安全、合规或适合特定目的。

## 9. 常见模型服务政策入口

下文列出 Palmi 当前快捷入口、代码中保留或常见的 OpenAI-compatible / 聚合 / 自定义模型服务可能涉及的政策入口。链接为本文件版本日整理的公开入口或官方控制台入口；服务商可能按国家/地区、账号类型、企业协议、API 产品、模型、托管方式和上游提供方展示不同文本。使用前请以服务商当前页面为准。

### 智谱 AI / GLM / Z.ai / BigModel

Palmi 当前可选的快捷模型入口之一；也可能由用户通过自定义 OpenAI-compatible endpoint 接入。

- [智谱开放平台 / BigModel 控制台](https://open.bigmodel.cn/)
- [Z.ai 官方入口](https://z.ai/)

使用前请在控制台或登录页确认其最新服务协议、隐私政策、开发者协议和数据处理条款。

### DeepSeek / 深度求索

Palmi 当前可选的快捷模型入口之一；也可能通过官方 API、聚合平台或自定义 endpoint 接入。

- [DeepSeek Privacy Policy](https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html)
- [DeepSeek Terms of Use](https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html)

### 自定义 OpenAI-compatible endpoint

用户自行填写 Base URL、API Key 和模型名；服务商可能是官方厂商、聚合平台、云厂商、企业网关、本地服务或个人自部署服务。

OpenAI-compatible 只表示接口形态兼容，不表示由 OpenAI 提供，也不表示隐私、留存、训练、删除、跨境传输规则相同。

请在 endpoint 所属服务商、组织网关或自部署系统中查阅当前有效的政策。

### OpenAI / ChatGPT

可通过自定义 endpoint、OpenRouter、Azure OpenAI 或其他托管方式出现。

- [OpenAI Privacy Policy](https://openai.com/policies/privacy-policy/)
- [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/)

### Microsoft Azure OpenAI / Azure AI Foundry

可通过 Azure 资源、企业账号或自定义 endpoint 接入。

- [Microsoft Privacy Statement](https://www.microsoft.com/en-us/privacy/privacystatement)
- [Azure OpenAI data, privacy, and security](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/openai/data-privacy)

### 阿里云百炼 / DashScope / 通义千问 / Qwen

可通过阿里云百炼或 DashScope OpenAI-compatible endpoint、自定义 endpoint 或聚合平台出现。

- [阿里云隐私权政策入口](https://www.aliyun.com/legal/privacy)
- [DashScope / 百炼文档入口](https://help.aliyun.com/zh/dashscope/)

使用企业账号时还应查阅阿里云服务协议、数据处理协议和所选区域规则。

### Moonshot AI / Kimi

可通过 Kimi / Moonshot 官方 API、自定义 endpoint 或聚合平台出现。

- [Moonshot AI 开放平台](https://platform.moonshot.cn/)
- [Kimi 官方入口](https://kimi.moonshot.cn/)

请以开放平台或登录页展示的最新隐私政策、服务协议和 API 条款为准。

### MiniMax / 海螺 / Talkie

可通过 MiniMax 官方 API、自定义 endpoint 或聚合平台出现。

- [MiniMax 官方网站](https://www.minimax.io/)
- [MiniMax 开放平台](https://platform.minimaxi.com/)

请以开放平台和账号后台展示的隐私政策、服务协议、API 条款为准。

### 火山方舟 / 豆包 / Volcengine Ark

可通过火山引擎方舟 OpenAI-compatible endpoint、自定义 endpoint 或聚合平台出现。

- [火山引擎隐私政策入口](https://www.volcengine.com/docs/6256/64902)
- [火山方舟文档入口](https://www.volcengine.com/docs/82379)

### 腾讯混元 / Tencent Hunyuan

可通过腾讯云混元 API、自定义 endpoint 或聚合平台出现。

- [腾讯云隐私保护声明](https://cloud.tencent.com/document/product/301/11470)
- [腾讯云服务协议入口](https://cloud.tencent.com/document/product/301/1967)

### 百度智能云千帆 / 文心 / ERNIE

可通过百度智能云千帆 endpoint、自定义 endpoint 或聚合平台出现。

- [百度隐私保护平台](https://privacy.baidu.com/policy)
- [百度智能云千帆文档入口](https://cloud.baidu.com/doc/WENXINWORKSHOP/)

### 阶跃星辰 / StepFun

可通过 StepFun 官方 API、自定义 endpoint 或聚合平台出现。

- [StepFun 开放平台](https://platform.stepfun.com/)

请以 StepFun 控制台展示的服务协议、隐私政策和开发者条款为准。

### ModelScope / 魔搭社区

可作为模型托管或推理服务入口出现。

- [ModelScope 官方入口](https://modelscope.cn/)

请阅读 ModelScope 服务协议、隐私政策和具体模型卡/许可证。

### SiliconFlow / 硅基流动

可作为国内模型聚合与推理平台出现。

- [SiliconFlow 官方入口](https://siliconflow.cn/)

请阅读其隐私政策、服务协议、模型服务条款和上游模型提供方规则。

### OpenRouter

可作为全球模型聚合平台出现；上游模型提供方也可能独立处理输入和输出。

- [OpenRouter Privacy Policy](https://openrouter.ai/privacy)
- [OpenRouter Terms of Service](https://openrouter.ai/terms)

还应阅读其 provider / data 页面和所选上游模型厂商政策。

### Ollama

主要用于本地或局域网模型服务；如果连接官方云端或远程托管服务，应另行阅读对应政策。

- [Ollama Privacy Policy](https://ollama.com/privacy)
- [Ollama Terms](https://ollama.com/terms)

### LM Studio

主要用于本地桌面或局域网模型服务；若启用远程下载、账号、同步或托管服务，应查阅其政策。

- [LM Studio Privacy](https://lmstudio.ai/privacy)
- [LM Studio Terms](https://lmstudio.ai/terms)

### Anthropic / Claude

Palmi 当前可选的快捷模型入口之一，通过 Anthropic 原生 Messages 接口接入；Claude 也可能通过 OpenRouter、企业网关或自定义 endpoint 出现。

- [Anthropic Privacy Policy](https://www.anthropic.com/legal/privacy)
- [Anthropic Terms and policies](https://www.anthropic.com/legal)

### Google Gemini / Google AI Studio / Vertex AI

可通过 Google 官方 API、Vertex AI、聚合平台或企业网关出现。

- [Google Privacy Policy](https://policies.google.com/privacy)
- [Google Cloud Privacy Notice](https://cloud.google.com/terms/cloud-privacy-notice)
- [Google AI / Gemini API additional terms](https://ai.google.dev/terms)

### Mistral AI

可通过 Mistral 官方 API、聚合平台或企业网关出现。

- [Mistral AI Legal Center](https://legal.mistral.ai/terms)
- [Mistral AI Privacy Policy](https://legal.mistral.ai/terms/privacy-policy)

### Meta / Llama

通常通过第三方托管、云厂商、聚合平台、本地部署或企业网关出现；Meta 公开模型许可不等同于托管服务隐私政策。

- [Meta Privacy Policy](https://www.facebook.com/privacy/policy/)
- [Llama official site](https://www.llama.com/)

还应阅读实际托管方、云厂商或本地部署者的政策。

### xAI / Grok

可通过官方 API、聚合平台或企业网关出现。

- [xAI Privacy Policy](https://x.ai/legal/privacy-policy)
- [xAI Terms of Service](https://x.ai/legal/terms-of-service)

### Cohere

可通过 Cohere 官方 API、聚合平台或企业网关出现。

- [Cohere Privacy Policy](https://cohere.com/privacy)
- [Cohere Terms of Use](https://cohere.com/terms-of-use)

### Hugging Face / Inference Providers

可作为模型下载、托管、推理、Spaces 或第三方 inference provider 入口出现。

- [Hugging Face Privacy Policy](https://huggingface.co/privacy)
- [Hugging Face Terms of Service](https://huggingface.co/terms-of-service)

还应阅读实际 inference provider 和具体模型许可证。

### Together AI / Fireworks AI / Groq / Replicate / Perplexity / AI21 Labs

这些服务可能通过自定义 endpoint、聚合平台、SDK、企业网关或上游托管方出现。

- [Together AI Privacy](https://www.together.ai/privacy)
- [Fireworks AI Privacy](https://fireworks.ai/privacy)
- [Groq Privacy Policy](https://groq.com/privacy-policy/)
- [Replicate Privacy](https://replicate.com/privacy)
- [Perplexity Privacy Policy](https://www.perplexity.ai/hub/legal/privacy-policy)
- [AI21 Labs Privacy Policy](https://www.ai21.com/privacy-policy)

### 讯飞星火 / 华为云盘古 / 商汤日日新 / 百川智能 / 零一万物 / 小米 / 美团等其他模型或托管入口

可能通过自定义 endpoint、云市场、企业网关、本地部署或聚合平台出现；具体政策随账号、地区、服务形态和托管主体变化。

- [讯飞开放平台隐私政策入口](https://www.xfyun.cn/doc/policy/privacy.html)
- [华为云隐私保护入口](https://www.huaweicloud.com/declaration/sa_prp.html)
- [小米隐私政策入口](https://privacy.mi.com/all/zh_CN/)

对于美团 LongCat、百川、零一万物、商汤等，请以其官网、开放平台或模型服务后台展示的最新政策为准。

如果某个服务未列入上文，仍应按照同样原则处理：确认 endpoint 归属、服务主体、上游提供方、适用区域、日志与训练政策、删除与导出方式、费用和合规限制。

## 10. 用户确认

1. 我理解 Palmi 是本机优先的 Agent 应用和模型接入界面，当前不以自有服务器作为集中式聊天内容、工作区文件、附件或 API Key 数据库。
2. 我理解当我配置或使用第三方模型、聚合平台、搜索源、系统服务、企业网关、本地/远程自部署 endpoint 或其他工具时，我选择发送的内容和必要元数据可能由对应服务处理。
3. 我理解第三方服务的数据留存、训练使用、上游转发、跨境传输、删除请求、账号安全、费用和争议处理，以该第三方当前有效政策和我与其之间的协议为准。
4. 我将只在有充分权利、授权和合规依据的情况下提交个人信息、企业资料、客户资料、文件、图片、代码或其他内容，并在高风险场景中进行人工复核。
5. 如果我不同意本提示或尚未确认所选服务商政策，我可以停止配置模型或返回修改选择。

本文件用于产品内用户知情和操作确认。它不是针对任何用户、组织、行业或法域的个别法律意见。正式发布、上架、商用或面向受监管行业使用前，建议由具备相应法域经验的专业人士审阅。
