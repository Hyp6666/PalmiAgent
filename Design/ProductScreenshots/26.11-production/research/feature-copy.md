# Palmi 26.11 — 功能证据与双语文案

研究日期：2026-10-30。范围：只读本地 README、更新记录、实现源码；未读取凭据或敏感运行配置，未修改应用或商店。未发现根目录及其上级适用的 AGENTS.md。26.11-fresh 是素材流程和少量初始素材，不能视作已完成的九图组。

## 内容定位

长期定位：在 iPhone 和 iPad 上，把日常对话、可交付成果的专业工作与虚拟角色对话放在同一应用。用户接入自己的模型服务；项目、会话、文件、工具与技能组成可继续使用的工作区。

26.11 重点：回复中可直接操作的内容；专业模式浏览器操控测试版；重整后的聊天入口、侧栏、模型管理和文件浏览。这些是版本变化，不能把端侧计算、技能、项目或仿生本身写成此次新增。

README 的“三模型方案”和“五种界面语言”已落后于本次代码：26.11 应写模型分组、默认模型与工具绑定；当前语言枚举共十一种。本报告以当前实现和本地 26.11 更新记录为准。

## 已核实的长期价值

| 价值 | 可公开的准确表述 | 代码证据（仓库相对路径） | 展示边界 |
| --- | --- | --- | --- |
| 三种模式 | 聊天、专业、仿生，用于不同类型的对话 | `Features/Workspace/PalmiDrawer.swift:48`；`Features/Workspace/AppShellModeViews.swift` | 下表中源码路径均相对 `PalmiAgent/` |
| 专业项目与过程 | 项目组织会话、资料和成果；可查看任务步骤、工具活动 | `Features/Workspace/WorkspaceStore.swift`；`Features/Chat/NeoRuntimeTimeline.swift`；`Features/Chat/AgentEvidencePanel.swift` | 不承诺每个任务都能成功完成 |
| 文件与文档 | 浏览、预览和分享项目文件；读取支持的 PDF、Office、iWork 文档内容 | `Features/Workspace/WorkspaceFileBrowser.swift:45`、`:97`、`:287`；`Core/DocumentIO/Breakdown/BreakdownModels.swift:4`；`Core/DocumentIO/Breakdown/Handlers/DocumentBreakdownHandlers.swift:70`、`:173` | 文档读取不等于完整编辑所有格式，不承诺无损保留原排版 |
| 网页研究 | 搜索网页、读取页面、批量获取来源、保留研究过程 | `Core/Actions/ToolAction.swift:32` 至 `:39`；`Features/Chat/AgentEvidencePanel.swift`；`Integrations/Web/WebModelToolAdapters.swift` | 搜索和网页访问需要可用网络及相应服务；来源并非自动保证结论正确 |
| 端侧计算 | 在设备上运行 Python 计算与数据处理，将脚本及结果记录留在项目中 | `Core/Sandbox/PythonNotebookSandboxService.swift:11`、`:32`、`:44`；`Core/Sandbox/EmbeddedPythonRuntime.swift`；`Core/Actions/ToolAction.swift:27` | 模型生成代码仍需接入服务；不写“整个 AI 离线运行” |
| 端侧 OCR | 图片文字识别使用随应用附带的识别资源 | `Integrations/OCR/PPocrv6TinyOCRService.swift:49`、`:78`、`:96` | 不承诺所有语言、版式或手写体的识别效果 |
| 可复用技能 | 导入技能，按全局或项目使用，保存自己的工作方法 | `Core/Skills/SkillRegistry.swift:35`、`:45`、`:85`、`:97`；`Core/Skills/SkillIOService.swift`；`Features/Workspace/SkillManagementScreens.swift` | 技能是操作说明及资源，不等于额外模型或任意系统插件 |
| 独立工作协作 | 专业任务可把互相独立的只读工作分给子智能体 | `Core/Agent/SubagentToolRuntime.swift:336`、`:354`、`:363` | 当前定义明确是只读子任务；不宣传每个子智能体都能写文件或操控设备 |
| 自选模型 | 连接兼容服务，管理模型并选择当前对话使用的模型 | `Core/ModelLibrary/ModelLibraryModels.swift:19`、`:67`、`:160`；`Features/Settings/ModelSettingsScreens.swift` | 模型能力、可用性、额度及费用取决于用户所选服务 |
| 仿生角色 | 创建虚拟角色，通过角色设定、记忆与对话延续虚构故事 | `Features/Bionic/BionicPersonaEditor.swift`；`Core/Bionic/BionicPromptBuilder.swift`；`Core/Bionic/BionicArchiveStore.swift` | 不暗示角色是真人、具备意识或具有真实生活 |
| 仿生 Pro | 一次性购买解锁更多角色和记忆详情、编辑、来源跳转与日记阅读 | `Features/Bionic/BionicPurchaseSheet.swift:100` 至 `:112`；`Features/Bionic/BionicDiaryScreen.swift:10`；`Features/Bionic/BionicHistoryScreen.swift:283`、`:354` | 免费版有内置角色和最多两个自定义角色；Pro 自定义上限 99；模型服务费用另计 |
| 本地工作区 | 对话、任务状态和项目文件保存在设备上 | `Core/Sandbox/WorkspaceManager.swift`；`Core/Agent/TaskStateFileStore.swift`；`Features/Workspace/WorkspaceStore.swift` | 请求所需内容仍发往配置的模型及搜索服务；不写“所有数据永不离开设备” |

## 26.11 变化与证据

版本清单：`PalmiAgent/Features/Updates/ReleaseNotesScreen.swift:5`、`:6`。中英更新原文：`PalmiAgent/zh-Hans.lproj/Localizable.strings:2040` 至 `:2052`；`PalmiAgent/en.lproj/Localizable.strings:2039` 至 `:2051`。

| 此版本变化 | 实现证据 | 对外范围 |
| --- | --- | --- |
| 打开后直接聊天；聊天和专业模式体验更一致；全新侧栏 | `Features/Workspace/WorkspaceShellScreen.swift`；`Features/Workspace/PalmiDrawer.swift`；更新项 `chat`、`interface` | 可用于版本更新；不需要占用长期卖点的整张海报 |
| 浏览器操控测试版；自然语言指挥、多页面、人工接手 | `Integrations/Web/BrowserOperatorService.swift`；`Integrations/Web/BrowserRuntimeTools.swift`；`Features/Chat/BrowserHubScreen.swift:5`、`:62`、`:145` | 必须保留 beta／测试版，以及专业模式限定；不宣传后台无限浏览或自动通过验证 |
| 模型分组、默认模型、会话内选择、旧配置迁移 | `Features/Settings/ModelSettingsScreens.swift:68`、`:90`；`Core/ModelLibrary/ModelLibraryState.swift:106`；`Core/ModelLibrary/ModelLibraryStore+Editing.swift:423`、`:431`；`Features/Chat/ChatScreen.swift:3159`；`Core/ModelLibrary/ModelLibraryMigrator.swift` | 模型切换发生在会话中，不暗示可以无损切换进行中的模型请求 |
| 自动审核、视觉、远端网页能力、图像生成的独立模型选择 | `Core/ModelLibrary/ModelLibraryModels.swift:232`；`Core/ModelLibrary/WebCapabilityModels.swift`；`Features/Settings/ToolCapabilitySettingsScreens.swift` | 所选服务必须具有对应能力；不写“任何模型都可以生成图片” |
| 原生交互组件与 HTML 小应用嵌入回复 | `Core/GenerativeUI/PalmiGenerativeUIPrompt.swift:8`；`Core/GenerativeUI/PalmiUIModels.swift:73`、`:109`；`SharedUI/GenerativeUI/AssistantMessageContentView.swift:19` | 可展示可调图表、计算器、小型游戏等真实生成结果；不能把某一固定游戏写成内置应用列表 |
| 流式回复、图文及交互内容衔接、下一句建议 | `SharedUI/GenerativeUI/AssistantMessageContentView.swift`；更新项 `replies`；`Features/Chat/ChatScreen.swift` | 实际输出取决于请求与模型；不承诺每条回复都有交互内容 |
| 集中查看项目文件、展开文件夹、预览及分享 | `Features/Workspace/WorkspaceFileBrowser.swift:45`、`:97`、`:398` | 这是文件浏览体验增强；项目文件能力本身是长期价值 |
| 跨界面浮动提问、连续回答、补充说明、回到会话 | `Features/Chat/UserQuestionOverlay.swift:4`、`:20`；`Features/Chat/UserQuestionService.swift`；`Features/Chat/UserQuestionSession.swift` | 指应用内部当前界面，不是系统级悬浮窗 |
| 后台工作及进度改进，包括仿生；移除应用原先固定时长及轮数中断 | `Core/Agent/AgentContinuedProcessingCoordinator.swift:26`、`:148`、`:248`；`Features/Chat/ChatStore.swift:2743`；更新项 `background` | iOS 仍管理后台执行并可能终止任务；不写“无限运行”“永不打断” |
| 仿生已读、未读提醒和聊天表现优化 | `Core/Bionic/BionicReadReceiptLedger.swift`；`Core/Bionic/BionicNotifications.swift`；更新项 `bionic` | 仿生模式并非 26.11 首次加入 |
| 新增德语、瑞典语、阿拉伯语、土耳其语、印尼语、法语 | `Core/Support/PalmiLanguage.swift:3` 至 `:10` | 当前共十一种界面语言；阿拉伯语枚举为埃及地区 |
| 浏览器收起后的会话保持、仿生侧栏模式修复 | 更新项 `navigation` | 属修复；不作为海报主标题 |

## 九图场景与主标题候选

每张只能选择一组主标题；`／` 表示建议显式换行，输出时替换为换行。每组最多两行。场景必须以实际运行结果拍摄；下表不是现成截图的认定。

| 顺序与内容 | 中文首选 | 英文首选 | 备用中文 / 英文 | 拍摄要点 |
| --- | --- | --- | --- | --- |
| 01 对话内交互，作为入口总览 | 把想法／变成可以玩的回答 | Ideas you can／play with. | 回答，也能动手试试 / Answers you can explore. | 回复中真实可操作的 2048、模拟或计算器；首屏同时可见自然语言对话，不能仅截游戏 |
| 02 专业任务与成果 | 从一个问题／做到一份成果 | From a question／to a finished file. | 让任务一步步有结果 / See your work take shape. | 真实已完成任务，时间线与可打开的文件；避免空白任务清单 |
| 03 浏览器操控 beta | 说出要做的事／浏览器接着做 | Give the browser／a task. | 网页上的工作，也能聊着做 / Put your browser to work. | 专业模式浏览器真实页面、控制状态或多页概览；画面原生 UI 需能体现 beta，商店文字保留 beta |
| 04 项目和文件 | 资料与成果／都在项目里 | Your files.／Your workspace. | 工作有了自己的位置 / A place for every project. | 有意义的文件夹、输入文件和成果文件；不同项目应有可辨识名称 |
| 05 模型选择 | 选你喜欢的模型／接着聊 | Your models.／Your choice. | 好模型，由你来选 / Choose what powers your chat. | 模型分组、默认项或会话选择器；画面避开禁止展示的公司名称、实际凭据与地址 |
| 06 网页研究与来源 | 追着问题／找到来源 | Follow the question.／Find the sources. | 查资料，也看得到出处 / Research with sources in view. | 真实研究回答与来源证据；不要伪造引用或使用无法访问的页面 |
| 07 端侧计算 | 让数据／在设备上算明白 | Work through data.／Right on your device. | 把数字，算成答案 / Turn numbers into answers. | 本地 Python 完成的清楚结果或图表；输入数据非敏感且可核对 |
| 08 技能 | 把好方法／留给下一次 | Keep your methods.／Use them again. | 熟悉的工作，有熟悉的做法 / Your workflow, ready again. | 已导入可读的技能与全局/项目范围；没有技能时不拍空列表 |
| 09 仿生 | 让角色与故事／慢慢延续 | Characters to meet.／Stories to continue. | 记得对话里的小事 / Stories that remember. | 明确虚构角色的自然对话或角色页；如拍记忆详情/日记阅读，应为已解锁 Pro 的真实状态 |

若仅制作八张，优先把 07 端侧计算并入 02 专业任务成果，并保留技能与仿生，以免全组退化为一次版本改动清单。端侧 OCR 可作为文件场景的替换项：中文“图片里的文字／也能接着用”，英文“Put the words／in your photos to work.”；必须展示真实 OCR 输出。

## 可提交商店文字：简体中文

### 推广文本

在 Palmi，把想法聊成可交互的回答，把资料整理成项目成果。接入你喜欢的模型，在 iPhone 和 iPad 上研究、计算、管理文件，也与虚拟角色延续故事。

### 描述

Palmi 是 iPhone 和 iPad 上的 AI 对话与工作空间。接入你选择的模型服务，从日常问答、写作和图片理解，到资料研究、数据计算与文件成果，让对话继续往前走。

回答，也可以动手试
在回复中探索可调图表、计算器、动画或小型游戏。文字、图片与可交互内容放在同一段对话里，帮助你理解问题、比较方案，试一试自己的想法。

给工作一个项目
在专业模式中，把会话、输入资料和成果放进项目。查看任务进度、工具活动和记录，随时补充要求。浏览文件夹，预览与分享文件，把工作结果带走。

查资料，看到来源
搜索网页，阅读页面与支持的文档，跟进线索，把资料整理成回答和文件。专业模式提供浏览器操控测试版：用自然语言指挥内置浏览器，查看多个页面，在需要登录或验证时亲自接手。

在设备上处理资料
运行本地 Python 计算与数据处理，识别图片文字，读取支持的 PDF、Office 和 iWork 文档。原始资料、中间文件和成果可以保存在项目工作区中。

选择自己的模型与方法
连接兼容的模型服务，按组管理模型，选择默认模型，并在对话中切换。为视觉、自动审核、远端网页工具和图片生成选择适用的模型。导入技能，将常用方法用于全局或指定项目。

与虚拟角色延续故事
仿生模式支持自定义角色设定、对话与记忆。基础版含内置 Palmi 角色，最多可保留两个自定义角色。一次性购买仿生 Pro 后，自定义角色上限提升至 99 个，并解锁记忆详情、编辑、来源消息跳转和日记阅读等功能。角色、故事与生成图片均为虚构内容。

使用前请准备模型服务
Palmi 不包含通用模型权重或第三方模型额度。你需要配置兼容的模型服务；模型、联网搜索和图像能力的可用性及费用取决于所选服务。仿生 Pro 不包含模型额度。

对话、项目文件与任务状态默认保存在设备上。请求所需内容直接发送至你配置的模型或搜索服务，并适用相应服务的条款与隐私政策。设备数据访问由系统权限和应用工具设置控制。后台任务的运行时间由 iOS 管理。

### 此版本新增内容

Palmi 26.11 带来可交互的回复、浏览器操控测试版，以及重新整理的聊天与工作界面。

• 可交互式回复：在对话中探索图表、计算器、动画和小型游戏，无须额外交互功能配置。回复边生成边呈现，文字、图片和交互内容自然衔接，并提供下一句建议。
• 浏览器操控测试版：在专业模式中用自然语言指挥内置浏览器，查看多个页面，需要登录或验证时亲自接手。
• 打开即聊天：聊天与专业模式的体验更加统一，新侧栏集中收纳历史会话、文件、技能与设置。
• 模型管理更新：按组管理模型并选择默认项，旧有三模型配置自动迁移，会话中也可切换模型。更多工具支持单独选择模型。
• 文件浏览增强：集中查看项目文件、展开文件夹、预览和分享文件，更方便地查看会话附件。
• 浮动提问：需要你决定时，问题显示在应用当前界面，支持连续回答、补充说明和返回发起提问的会话。
• 后台体验改进：进度更新更及时，仿生回复也支持后台进度；移除应用原先固定时长和轮数造成的长任务中断。实际后台运行仍由系统管理。
• 仿生优化：改进角色对话、消息已读状态与未读提醒。
• 新增德语、瑞典语、阿拉伯语、土耳其语、印尼语和法语，并改善回复与会话标题对语言选择的遵循。
• 修复收起浏览器后丢失当前会话，以及从仿生模式打开侧栏时选错模式的问题。

## Store-ready copy: English (United States)

### Promotional text

Turn ideas into interactive replies and research into project files. Bring your models to Palmi on iPhone and iPad, and keep your work and stories moving.

### Description

Palmi brings AI conversations and a practical workspace to iPhone and iPad. Connect your chosen model service for everyday questions, writing, image understanding, research, calculations, and files you can use.

Answers you can explore
Try adjustable charts, calculators, animations, or small games inside a reply. Text, images, and interactive content stay together in the conversation so you can compare options and try out an idea.

A project for your work
Use Professional mode to organize conversations, source material, and results in projects. Follow task progress, inspect tool activity, and add instructions as work continues. Browse folders, preview files, and share the results.

Research with sources in view
Search the web, read pages and supported documents, follow leads, and turn findings into answers and files. Browser control is available in beta in Professional mode: direct the built-in browser in everyday language, view multiple pages, and take over for sign-in or verification.

Work with data on your device
Run local Python calculations and data processing, recognize text in images, and read supported PDF, Office, and iWork documents. Keep source material, intermediate files, and results in your project workspace.

Your models and methods
Connect compatible model services, organize models into groups, choose a default, and switch models in a conversation. Choose suitable models for visual assistance, automatic tool approval, remote web tools, and image generation. Import skills to reuse your methods across the app or in a specific project.

Characters and ongoing stories
Bionic mode supports custom fictional characters, conversations, and memories. The basic plan includes the built-in Palmi character and up to two custom characters. A one-time Bionic Pro purchase raises the custom-character limit to 99 and unlocks memory details, editing, links to source messages, diary reading, and more. Characters, stories, and generated images are fictional.

Bring a model service
Palmi does not include general-purpose model weights or third-party model credits. Configure a compatible service to get started. Model, web, and image capabilities, availability, and costs depend on your service. Bionic Pro does not include model credits.

Conversations, project files, and task state are stored on your device by default. Content needed for a request goes directly to your configured model or search service, subject to that service's terms and privacy policy. Access to device data follows system permissions and app tool settings. iOS manages background execution time.

### What's New

Palmi 26.11 introduces interactive replies, browser control in beta, and a refreshed conversation and workspace experience.

• Interactive replies: Explore charts, calculators, animations, and small games in a conversation, with no extra interactive-feature setup. Replies appear as they are written, combining text, images, and interactive content, with suggested next messages.
• Browser control, in beta: Direct the built-in browser in everyday language in Professional mode, view multiple pages, and take over for sign-in or verification.
• Open straight into a conversation: Chat and Professional modes feel more consistent. A new sidebar brings together history, files, skills, and settings.
• Updated model management: Organize models into groups, choose a default, and switch in a conversation. Previous three-model settings migrate automatically. More tools can use separately selected models.
• Better file browsing: Browse project files together, open folders, preview and share files, and access conversation attachments more easily.
• Floating questions: When Palmi needs a decision, answer over your current app screen, add details, move through questions, or return to the conversation that asked.
• Improved background work: Progress updates are more timely, including for Bionic replies. Previous app-imposed time and turn limits no longer interrupt long tasks. Background execution remains subject to system management.
• Bionic improvements: Better conversations, read status, and unread reminders.
• Added German, Swedish, Arabic, Turkish, Indonesian, and French, with better language matching in replies and conversation titles.
• Fixed losing the current conversation after collapsing the browser and selecting the wrong mode when opening the sidebar from Bionic mode.

## 发布前文案检查

字段长度已用脚本核对（包含正文中的换行）：中文推广文本 79／170、描述 843／4000、版本更新 546／4000；英文推广文本 154／170、描述 2602／4000、版本更新 1790／4000。全部通过。

商店字段与海报候选均避开指定的两家公司名称；没有使用对立式套话。宣传文本强调功能与工作场景，未把 README 中陈旧的三模型方案或语言数量复制进当前描述。以上均为候选文案文件，未提交商店。

主标题不得在实际 UI 尚未显示对应功能时使用。生成游戏、图表、图片和成果的质量依赖所选模型，应拍摄真实可用的结果。截图中若出现凭据、真实服务地址或受限制的公司名称，应改用应用已有的非敏感展示状态或重新选择场景，不能涂改 UI。
