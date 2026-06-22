# PalmiAgent

PalmiAgent 是一个 SwiftUI iOS 工作区应用，用来把对话、项目文件、模型方案、多模态输入、本地 OCR、网页研究、Python 执行和受控系统工具放进同一个任务环境里。

<p align="center">
  <img src="Screenshots/palmi-multimodal-image-analysis.png" width="320" alt="PalmiAgent 多模态图片分析">
</p>

## 它能做什么

- 在项目和线程中运行对话，让文件、附件、工具结果和聊天记录都跟随当前任务保存。
- 用模型方案管理主模型、多模态模型和轻模型角色，可接入 GLM/Z.AI、DeepSeek、本地服务或自定义 OpenAI-compatible endpoint。
- 支持图片输入、多模态模型扫描和本地 OCR；随包包含 PP-OCRv6 Tiny 资源，用于图片文字识别。
- 在任务运行时流式显示模型思考内容，并把工具调用、阶段进展、总结和最终回复组织成结构化聊天卡片。
- 提供工作区文件工具：读取、写入、追加、移动、复制、删除、列目录、预览生成文件和导出文件夹。
- 内置 CPython 运行时和一组纯 Python 包，用于计算、数据处理、解析、笔记本式脚本和工作区自动化。
- 提供网页研究能力：搜索源探测、网页搜索、静态正文读取、批量抓取和应用内网页预览。
- 可按用户授权调用 iOS 能力，包括日历、提醒事项、通讯录、定位、照片、相机、通知、语音、Spotlight、App Intents、地图、邮件、短信、电话、FaceTime、图书、播客、视频和应用设置。

## 核心概念

**工作区**

每个任务都在 PalmiAgent 管理的本地工作区里运行。项目包含线程，每个线程都有自己的文件区域，用来保存附件、生成物、OCR 输出、Python 日志、网页抓取结果和聊天状态。

**模型方案**

模型方案描述一次任务应该怎样分配模型角色：

- 主模型负责驱动主要 Agent 循环。
- 多模态模型负责在主模型无法直接看图时处理图片理解。
- 轻模型负责标题、压缩、小型辅助任务等低成本调用。

模型候选可以先加入再验证，验证结果作为提示信息，不阻断配置。每个线程也可以临时覆盖全局模型方案。

**工具**

工具按能力和风险分组。只读操作、工作区写入、个人数据访问、系统界面跳转和持久化系统改动都有独立元数据和授权路径。用户可以选择每次询问、全部同意或自动审查。

**技能**

技能是 Markdown 包，可以带元数据。技能可安装为全局技能或项目技能，可启用、禁用，并在当前工作区中注入到 Agent 提示词里。

## 多模态流程

消息包含图片时，PalmiAgent 会根据当前模型配置选择合适路径：

1. 主模型支持视觉时，直接把图片内联给主模型。
2. 主模型不适合看图时，调用已配置的多模态模型扫描图片。
3. 需要文字提取时，使用本地 OCR 输出结构化识别结果。

OCR 会在工作区写出 `.ocr.txt` 和 `.ocr.json`，包含识别文本、置信度、位置框和模型资源信息。

## 界面

PalmiAgent 有两个主要使用界面：

- **聊天模式**：适合直接对话、快速提问和图片理解。
- **专业工作区模式**：适合管理项目、线程、文件、技能和长任务。

输入框支持标准聊天、目标模式和深度研究模式。目标和深度研究是单轮任务提示模式，不改变工具运行时，但会影响 Agent 如何规划、推进和汇报任务。

## 隐私与安全

- API Key 由用户在运行时配置，通过应用配置层保存。
- 仓库不包含通用大模型权重，也不包含模型服务本身。
- 工作区文件默认保存在应用容器中，除非用户主动导出。
- 涉及个人数据、系统界面、工作区改动或持久化系统改动的工具调用会在运行时被单独标识。
- 应用进入后台时会刷新当前聊天状态，提升中断后的会话恢复可靠性。

## 环境要求

- macOS、Xcode，以及 iOS 26.1 SDK。
- Swift 5 项目设置。
- 真机运行需要在 Xcode 中配置 Apple 开发团队。
- 运行时需要能访问你准备使用的模型 endpoint。

## 构建

1. 用 Xcode 打开 `PalmiAgent.xcodeproj`。
2. 选择 `PalmiAgent` scheme。
3. 选择 iOS 模拟器或已签名的真机。
4. 等待 Xcode 解析 Swift Package 依赖。
5. Build and Run。

项目通过 Swift Package Manager 使用 MarkdownUI，vendored ZIPFoundation 处理归档，内嵌 CPython 支持 Python 工具，并随包提供 PP-OCRv6 Tiny OCR 资源。

## 目录结构

- `PalmiAgent/Core/Agent` - Agent 循环、上下文组装、工具路由、上下文压缩、任务状态、思考内容和多模态路由。
- `PalmiAgent/Core/Configuration` - API 配置和模型方案存储。
- `PalmiAgent/Core/LLM` - OpenAI-compatible 模型接入、能力元数据、推理控制和运行时选择。
- `PalmiAgent/Core/Sandbox` - 工作区存储、文件操作和 Python 执行。
- `PalmiAgent/Core/Skills` - 技能包解析、导入、注册和提示词组装。
- `PalmiAgent/Features/Chat` - 聊天界面、消息状态、附件、工具卡片、思考内容展示和上下文控制。
- `PalmiAgent/Features/Workspace` - 项目列表、线程导航、文件浏览、设置、模型控制和技能界面。
- `PalmiAgent/Integrations` - 模型调用、网页研究、OCR、媒体、个人数据、系统跳转和 App Intents。
- `PalmiAgent/SharedUI` - 可复用 SwiftUI 组件、文件预览、附件 UI、可选择文本和视觉效果。
- `Vendor/PythonSupport` - 内嵌 Python 运行时和精选 Python 包。
- `PalmiAgent/Resources/OCR` - PP-OCRv6 Tiny 模型资源和声明。

## 许可证

PalmiAgent 使用 Apache License 2.0。

第三方组件继续遵循各自许可证，见 `THIRD_PARTY_NOTICES.md`。

## English

English documentation is available in `README.md`.
