# PalmiAgent

PalmiAgent 是一个本地优先的 iOS Agent 工作区，用于把 OpenAI-compatible
模型、项目上下文、工具、技能和精致的 SwiftUI 聊天体验放在同一个应用里。

<p align="center">
  <img src="Screenshots/palmi-chat.jpg" width="260" alt="PalmiAgent 聊天界面">
  <img src="Screenshots/palmi-extreme-config.jpg" width="260" alt="PalmiAgent 极致能力配置">
</p>

## 特性

- 支持聊天模式和专业工作区模式，既能轻量对话，也能围绕项目推进任务。
- 支持 hosted API、本地模型服务器和自定义 OpenAI-compatible endpoint。
- 内置 OpenAI、Azure OpenAI、DeepSeek、通义千问、Kimi、MiniMax、火山方舟、腾讯混元、百度千帆、阶跃星辰、ModelScope、SiliconFlow、OpenRouter、LM Studio、Ollama 和自定义 OpenAI-compatible 配置。
- 提供「效率」「质量」「极致」三档能力配置，其中「极致」包含 Metal 驱动的动态视觉效果。
- 工具运行时支持工作区文件、嵌入式 Python、网页调研、附件和部分 iOS 系统能力。
- 项目技能和上下文层可用于调整模型行为，而不需要把所有提示词硬编码到聊天界面里。

## 环境要求

- macOS 和包含 iOS 26.1 SDK 的新版 Xcode。
- Swift 5 项目设置。
- 真机运行需要在 Xcode 中配置 Apple 开发团队。
- 用户需要在运行时自行配置 API Key 或本地模型服务器。

## 开始使用

1. 用 Xcode 打开 `PalmiAgent.xcodeproj`。
2. 选择 `PalmiAgent` scheme。
3. 选择 iOS 模拟器或已签名的真机。
4. 让 Xcode 自动解析 Swift Package 依赖。
5. Build and Run。

PalmiAgent 不包含任何模型权重。使用 hosted API 或本地模型之前，需要先在应用内配置对应 provider。

## 仓库说明

公开仓库会排除本地 agent 指令、参考仓库、内部 spec 和验证提示。具体包括
`AGENTS.md`、`CLAUDE.md`、`docs/`、`TestPrompts/`、`reference/` 和本地工具状态文件。

## 许可证

PalmiAgent 使用 Apache License 2.0。你可以使用、修改、分发和商业化本项目，但需要遵守许可证条款。

第三方组件继续遵循各自许可证，见 `THIRD_PARTY_NOTICES.md`。
