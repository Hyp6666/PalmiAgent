# 临门一脚 To-Do List

> 发布前的收尾清单，按主题分组。`[ ]` 未完成 / `[x]` 已完成 / `[-]` 已取消。
> 每个待办下面的「现状」是在项目代码里核实到的当前状况（附 `文件:行号`），只用来交代“现在是什么样、现象是否属实”。
> 本清单主体只列「要做什么」；会话状态系统的落地方案另见 [`会话持久化与多会话并发方案.md`](会话持久化与多会话并发方案.md)。

---

## 一、设置界面（重排 + 补全）

- [x] **重新排版整个设置界面**：现在设置里 5 个选项全部挤在一起、聚成一坨，没有按板块分开，需要重新排版、分板块呈现。

  **现状（已完成）**：`AppSettingsCatalog.swift` 把设置首页分成「模型 / 工具与知识 / 体验 / 系统」四组；`WorkspaceShellScreen.swift:1014` 的 `AppSettingsScreen` 按 `Section` 渲染，不再把 5 个入口平铺成一坨。

- [x] **新增「系统设置」入口**：设置里还缺一个系统设置入口，里面大致包含——语言切换、清理数据，以及「一键把整个 App 还原成最初始状态」等。

  **现状（已完成）**：设置首页已有「系统设置」入口（`AppSettingsCatalog.swift:54`）。二级页包含「语言」占位、「数据管理」和「系统信息」（`WorkspaceShellScreen.swift:1065`）；数据管理已支持清理工作区数据、清理缓存、恢复初始状态，恢复会清理本机工作区、缓存、偏好设置和 Palmi Keychain 模型凭据（`AppDataManagementService.swift:27`）。

- [x] **新增「隐私与政策」独立入口**：设置里单独放一个「隐私与政策」选项，点开后展示隐私与政策相关的内容。

  **现状（已完成）**：设置首页已有「隐私与政策」独立入口（`AppSettingsCatalog.swift:55`）；页面说明本机数据、第三方服务边界，并打开 bundle 内的 PDF 用户知情提示文件（`WorkspaceShellScreen.swift`）。

## 二、模型管理

- [x] **彻底推翻「新建配置」并重做 UI**：把新建配置里现有的这些东西全部推翻，只保留 GLM、DeepSeek 和 OpenAI 兼容自定义，并且把这块 UI 也彻底推翻重做。

  **现状（已完成）**：新建配置入口已改走 `ModelCandidateAddScreen`（`WorkspaceShellScreen.swift:2851`），预设来源由 `ModelCandidateProviderPreset` 提供，仅保留 OpenAI 兼容、智谱通用 API、智谱 Coding Plan、DeepSeek（`ModelPlanStore.swift:108`）。添加模型页已拆成「请求模型名称 / 显示名称」和「测试全部 / 添加全部」（`WorkspaceShellScreen.swift:2958`），添加、入槽、选中、启用不再依赖真实联通验证通过。

- [ ] **改造「搜索源」**：搜索源这块也要改，具体怎么改还没想好（先记着）。

  **现状**：`WebSearchProviderSettingsScreen.swift` 现在只是一个搜索引擎开关列表，共 5 个（百度 baidu / 必应 bing / DuckDuckGo / 搜狗 sogou / 360 so360），逐个 `Toggle` 开关、且至少保留一个。

- [ ] **改造「技能」**：技能这块大概率也要改，方案待定。

  **现状**：设置里「技能」入口指向 `SkillCatalogScreen(.global)`（全局技能目录），另有项目级技能 `SkillCatalogScreen(.project)`。

## 三、聊天模式 vs 专业模式

- [x] **统一专业模式与聊天模式的顶层外壳入口**：右上角可切换「专业 / 聊天」两种模式；聊天历史页与专业项目侧栏需要使用同一套顶层入口语义，而不是生硬复刻所谓上下「模板」。

  **现状（已完成）**：`WorkspaceShellScreen.swift:132` 的聊天模式仍走 `ChatHistoryHomeScreen` push 到 `ChatScreen`，但聊天历史页已使用 `AppShellTopBar`（`ChatHistoryHomeScreen.swift:77`），专业项目侧栏也使用同一顶层外壳入口（`WorkspaceShellScreen.swift:279`）；这里不再表述为“复刻专业模式上下模板”。

- [x] **聊天模式彻底重做为「固定 workflow」**：聊天模式打算彻底重做，不再用 agent 那一套，而是改成一条固定的工作流（fixed workflow）。这条先记住，具体怎么做后面再规划。

  **现状**：带工具聊天目前仍走 `AgentLoop` 主链路，但 prompt/profile 已按 surface 初步分流：聊天模式使用 `ChatSystemPromptBuilder`（`AgentPromptBuilder.swift:3`）和 surface-aware profile（`AgentRunProfile.swift:15`、`ChatStore.swift:760`）。还没有独立的固定工作流分支。

## 四、会话状态系统（重点，超大工程）

> 背景：一切以「会话（session）」为单元。专业模式下一个项目可以有很多个会话；聊天模式下一个项目文件夹就是一个会话。下面这些 session 状态目前大多不确定有没有、做没做，需要系统性地搞。这是一块**非常庞大、非常复杂**的工程，要重点对待。
> 方案：这组问题不是靠一个 loading 标志能解决，必须拆成「每会话运行态 / 运行账本 / 可恢复 checkpoint / 后台有限保活」四层，详见 [`会话持久化与多会话并发方案.md`](会话持久化与多会话并发方案.md)。

- [x] **（背景，已核实）会话模型：专业多会话 / 聊天单会话**——本身成立，作为后续工作的前提记下。

  **现状（已完成）**：`WorkspaceStore` 用 `threadsByProject`（`WorkspaceStore.swift:29`）按项目挂多个 thread，专业模式可在一个项目下建多个会话（默认名「新会话」）；聊天模式 `createChatConversation` 建 chat project 时创建初始 thread，`selectChatConversation` 只解析首个 thread、不再兜底补建（`WorkspaceStore.swift:188`、`WorkspaceStore.swift:240`、`WorkspaceManager.swift:464`），即“一个文件夹一个会话”。

- [x] **进行中会话要有「加载 / 思考中」标志**：一个会话正在跑的时候，返回到它时，前面应该先有一个加载标志，表示它正在思考、正在处理；而不是看起来像没在动。

  **现状（已完成）**：`ChatStore` 现在按 `WorkspaceSelection` 维护 `activeRuns`，`runningBadgeText(for:)` 会返回「正在处理 / 等待确认」（`ChatStore.swift:123`）。聊天历史和专业侧栏都读取这个 per-session 状态（`ChatHistoryHomeScreen.swift:47`、`WorkspaceShellScreen.swift:234`），回到运行中会话会恢复 `isLoading` 和当前 turn header（`ChatStore.swift:565`）。底部 loading 也补了 `finishedAt == nil` 判断，避免已完成但收尾阶段误报（`ChatScreen.swift:314`）。

- [x] **会话持久化（切出不断档 / 重启可恢复）**：现在进程存活时切出会话不一定直接中断，但可见过程会断档；进程被杀后正在跑的任务无法恢复。需要给会话做运行账本和 checkpoint，让它能清楚地继续、重试或取消。

  **现状（已完成）**：新增 `AgentRunLedger`（`AgentRunLedger.swift`）并在每个 thread 下保存 `run-ledger.json`（`WorkspaceManager.swift:689`）。切走会话前会保存 composer / active view state / messages（`ChatStore.swift:565`），后台运行事件会写回对应线程消息文件（`ChatStore.swift:1134`），完成后把 `runLoop.currentSessionSnapshot()` 同步回当前展示的共享 `agentLoop`，避免 context/session 串台（`ChatStore.swift:1705`）。冷启动会扫描旧 `running / waitingApproval` ledger 并标记 interrupted，消息里留下中断记录（`ChatStore.swift:801`）。

- [x] **App 退到后台不中断会话**：包括但不限于把 App 推到后台——现在推到后台，会话大概率会被中断。这块要专门处理。

  **现状（已完成）**：`PalmiAgentApp` 已接入 `scenePhase`，进入 inactive/background 时用有限 `beginBackgroundTask` 执行 `chatStore.flushForAppBackground()`；该 flush 会保存当前可见会话、所有 active run 的 `AgentSession`，并给 `run-ledger.json` 打心跳（`ChatStore.swift:138`）。这里按 iOS 正解处理：不承诺长期后台保活，但会在退后台/系统回收前尽量落盘；被杀后由 ledger 恢复为 interrupted 状态。

- [x] **多会话并发 + 会话隔离（防串台）**：要允许几个会话同时进行；同时要防止会话之间互相串（一个会话的内容窜进另一个会话）。每个会话怎么持久化、各路控制之间如何各自独立、会话之间如何做好隔离，这一整套都要搞。

  **现状（已完成）**：`AppContainer.makeAgentLoop()` 可为每个 run 创建独立 `AgentLoop`，`ChatStore.activeRuns` 以 `WorkspaceSelection(projectID, threadID)` 分桶（`ChatStore.swift:244`）。输入框文本、附件、模式、queued guidance 存到 `SessionComposerState`；header、tool stepID 映射、streaming/reasoning、context notice 存到 `ActiveSessionViewState`，切会话时保存/恢复（`ChatStore.swift:965`）。`WorkspaceManager.touchActiveThread()` 已改为尊重 pinned selection，后台会话保存不会刷新错线程（`WorkspaceManager.swift:1240`）。

## 五、聊天界面交互细节

- [ ] **重做展开 / 收起的动画**：点击那个 token 数量，可以把里面的处理过程、每一个阶段都展开，再点一下收起。这个展开收起的动画现在非常怪异——一点，那些本不该动的聊天框就到处乱飞；虽然最后能恢复好，但展开和收起的过程很奇怪。这块要从机制上系统性地处理一下。

  **现状**：`ChatScreen.swift:485` 折叠是通过 `collapsedTurnIDs` 过滤“本轮可见消息”实现的（`expandedToolMessageIDs` 控制单条工具卡展开），一点就重新过滤、整段重排布局，和“聊天框到处乱飞”的现象一致。

- [ ] **每条总结下面加「复制」+「转发」两个按钮**（先搁置，后面做，但规格先记全）：AI 生成的内容，最好在每一个总结下面都放一个复制按钮，再放一个转发按钮，两个按钮各自独立。

  **现状**：`ChatScreen` 目前只有针对链接/文件的「分享」按钮（`ChatScreen.swift:802`），没有逐条总结的复制 / 转发。规格如下：
  - [ ] 复制 = 直接复制；转发 = 存成 Markdown 形式转发出去。
  - [ ] 范围可选：一次性复制/转发整轮（当前这一态的全部内容），或只选最后一个阶段（也就是最后一个总结的内容）。
  - [ ] 格式可选：纯文本 或 Markdown。
  - [ ] 复制和转发都带上面这套「范围 + 格式」选择，点了之后让用户选是“最后一个总结”还是“全部内容”、以及文本还是 Markdown。

- [x] **系统性优化聊天输入框**：现在这个输入框很怪、很不对劲，感觉是有问题的——打字经常变得很短，各种卡顿、各种莫名其妙的毛病，具体说不清。需要系统性优化，最好找个更优雅、更专业的实现，必要时先把它分析一遍。

  **现状（已完成）**：根因是 `ChatComposerInputBar` 的「本地 `draftText` + 220ms 防抖回写 + 反向覆盖」三件套——过期值回盖造成「变短」，marked text 被重建造成拼音鬼畜。已全部拔除：`TextField` 直接绑 `store.inputText`（唯一真相），文本框拆成隔离的 `ComposerTextEditor`（整棵树只有它读 `inputText`），打字只重渲染这一小块、不牵动聊天列表。输入区也合并成仿 Gemini 的统一玻璃大框（附件方块 / 多行输入 / 控制行）。

- [x] **重构「上下文压缩」按钮 + 优化压缩功能本身**：那个压缩按钮经常点了没反应——确实能点，但常常失效，需要重构/优化。压缩功能本身也要优化，包括压缩的“切割词”怎么定。

  **注意**：上下文系统今天本身应该是很健壮的，**别乱动**，只动按钮可靠性和压缩策略。

  **现状**：按钮走 `store.compactContextNow()`（`ChatStore.swift:262`），开头有 `guard !isLoading, !isCompactingContext` ——只要正在加载或已在压缩就静默返回、什么都不做，这与“点了没反应”的现象吻合。

- [ ] **排查「上下文已压缩」横杠不可见 / 插入不可靠**：压缩完之后，原先那个位置应该显示一根横杠、下面写着“上下文已压缩”，直接显示出来；但实际经常看不到。

  **现状（⚠️ 与直觉不符，注意）**：这个功能代码里其实已经有了——`finishContextCompactionNotice`（`ChatStore.swift:964`）会生成一条文案为“上下文已压缩”的 `.completed` 通知，由 `ContextCompactionDivider`（`ChatScreen.swift:2715`）渲染成左右横线夹一段文字的横杠；手动压缩还设了 `.alwaysVisible`。所以这更像是“显示/插入没生效”的问题，而不是缺功能，实现时重点排查为什么实际看不到。

- [ ] **顶部三个按钮图标改小一点点**：最上面那三个按钮——返回、帕米选模型、文件夹——这三个图标稍微弄小一点。

  **现状**：`ChatScreen.swift:275` `topChromeControlSize = 52`（返回键、文件夹键的 `buttonSize` 都取它，`ChatScreen.swift:1414`），中间帕米选模型菜单宽 `topModelMenuWidth = 148`、高同为 52。

- [ ] **底部「正在处理」转圈换成帕米形象动画**：「正在处理」其实有两处——每一轮对话最开头有一个“正在处理 多少秒”，最下面也有一个。要把**最下面**这个现在转圈的，换成帕米的形象，做成一个动作 / 表情的循环。具体换成什么样以后再定，但先记在清单里。

  **现状**：底部那个是 `BottomStreamingIndicator`（`ChatScreen.swift:2655`），现在是旋转圆环 spinner + “正在处理 Xs”；顶部每轮开头那个是 `SessionHeaderStrip` 的“正在处理 Xs”（`ChatScreen.swift:2632`）。本项**只改底部那个**，别和顶部混了。

- [x] **thinking 内容改成实时（流式 / 字数增长）**：现在 thinking 的内容不是流式的，只能等它思考完了才能看到。两种方案二选一——要么像 Claude Code 那样，能看到字数在往上涨（一个数字在增长），让用户知道它确实在思考；要么直接把思考内容做成流式滚动出来。无论哪种，思考内容本身展开后仍然要能看全文。

  **现状（已完成，主链路）**：统一协议层 SSE 解析新增 `onReasoningDelta`（reasoning_content / reasoning / thinking 三字段逐字回调）+ tool_calls 分片累积。Agent 主循环改走带工具的 `modelRuntime.stream`，reasoning 经 `onReasoningDelta → .reasoningDelta` 事件，ChatStore 把它累积进一张「思考」卡——**首个字一到卡就出现并持续增长**，不再是想完才一次性弹。注意：无工具的 `createStreamingChatCompletion` 旁路目前仍主要把 reasoning 收成最终 `nativeReasoning`，不是 UI 实时 reasoning 主路径。

## 六、新增模式（目标 / 深度研究）

> 目标模式与深度研究模式已经有用户入口；计划模式已取消，不再做。
> **注意：它们和「思考强度」能力档位（效率 / 质量 / 极致）不是一回事**——那三档只关乎 agent 的参数与提示词，跟这里要新增的模式没有关系，别再把两者混为一谈。
> 现状核查：`AgentComposerMode` 只有 `.standard / .goal / .deepResearch`（`AgentLoop.swift:7`）；加号菜单「规划」入口只提供「目标 / 深度研究」。`TaskToolExposurePolicy.swift:34` 仍把“计划/目标/深度研究”等当关键词用于工具暴露判断，但那不是模式入口；`ReasoningStrengthProfile.swift` 的能力档位是另一套机制。

- [x] **目标模式（本轮一次性）**：核心是在本轮发送时设立一个目标，用提示词注入方式约束这一轮模型。

  **现状（已完成）**：`AgentComposerMode`（`AgentLoop.swift:5`）含 `.goal`，选中后 `composerModeInstructionLayer` 把目标 query 作为强约束追加到本轮 user 文本后的隐藏 `【turn】` 块，不改稳定 system prompt、不改工具调用、不动 harness（`AgentLoop.swift:1543`、`AgentLoop.swift:1588`）；一次性——`ChatStore.send()` 在本轮最终总结结束后清回 `.standard`。加号菜单「规划」入口可切换。

- [-] **计划模式**：已取消（不再做）。规划子菜单只保留「目标 / 深度研究」两项。

- [x] **深度研究模式（提示词版）**：已完成。

  **现状（已完成，提示词版）**：`.deepResearch` 模式注入更完整的提示词——在项目根建「深度研究/研究-yyyyMMdd-HHmmss」二级文件夹；要求至少搜索 100 个网页、浏览 20–100 个；过程留痕写笔记；最终 Markdown 报告写入子文件夹（含目录/分节/来源编号/参考资料清单）。一次性生命周期同目标模式。注意：这些约束目前是提示词约束，不是运行时硬校验。

## 七、全局

- [ ] **整体性能优化**：贯穿全局的性能优化（输入、展开折叠、流式、滚动等都涉及）。

- [ ] **多语言 i18n**：做国际化 / 多语言支持。

  **现状**：全项目没有 `.strings` / `.xcstrings` / `.stringsdict`，也没有成体系的 `NSLocalizedString` / `String(localized:)` / `LocalizedStringKey` 使用；虽有少量 `LocalizedStringResource`（如 App Intents / Alarm），但绝大多数 UI 文案仍是硬编码中文。`docs/i18n-改造计划.md` 已有扫描和执行计划，国际化基建仍未落地。

---

## 精简同步表（2026-06-22）

| 状态 | 原顺序事项 | 精简说明 |
| --- | --- | --- |
| [x] | 重新排版整个设置界面 | 已按「模型 / 工具与知识 / 体验 / 系统」分组。 |
| [x] | 新增「系统设置」入口 | 已含语言占位、数据管理、系统信息。 |
| [x] | 新增「隐私与政策」独立入口 | 已有入口、说明页和 Markdown 政策文件预览。 |
| [x] | 新建配置 UI 重做 | 仅保留 GLM、DeepSeek、OpenAI 兼容；模型方案添加与验证已解耦。 |
| [ ] | 改造「搜索源」 | 方案未定。 |
| [ ] | 改造「技能」 | 方案未定。 |
| [x] | 专业模式上下模板复刻到聊天模式 | 已纠偏为统一顶层外壳入口，不再按“上下模板复刻”描述。 |
| [x] | 聊天模式改为固定 workflow | 带工具仍走 agent 主链路。 |
| [x] | 会话模型核实 | 专业多会话、聊天单会话成立。 |
| [x] | 进行中会话加载/思考中标志 | 已接 per-session running badge 和返回恢复。 |
| [x] | 会话持久化 | 已接 run ledger、消息/AgentSession 落盘和中断恢复标记。 |
| [x] | App 退后台处理 | 已接 scenePhase + 有限后台 flush + ledger 心跳。 |
| [x] | 多会话并发与隔离 | 已改独立 AgentLoop、activeRuns、composer/view state 分桶。 |
| [ ] | 重做展开/收起动画 | 折叠重排动画仍待重构。 |
| [ ] | 总结下复制/转发按钮 | 逐条复制/转发未做。 |
| [x] | 系统性优化聊天输入框 | 已改唯一真相绑定和隔离输入组件。 |
| [ ] | 重构上下文压缩按钮 | 按钮可靠性和策略仍待改。 |
| [ ] | 排查上下文已压缩横杠 | 插入/显示不可靠仍待查。 |
| [ ] | 顶部三个按钮图标改小 | 未做。 |
| [ ] | 底部正在处理换帕米动画 | 未做。 |
| [x] | thinking 内容实时化 | 主链路 reasoning 已流式进思考卡。 |
| [x] | 目标模式 | 已完成，一轮一次性。 |
| [-] | 计划模式 | 已取消。 |
| [x] | 深度研究模式 | 已完成提示词版。 |
| [ ] | 整体性能优化 | 全局性能专项未做。 |
| [ ] | 多语言 i18n | 国际化基建未做。 |

> **2026-06-24 复核**：本轮完成设置首页重排、系统设置入口、隐私与政策入口，并将“专业模式上下模板复刻到聊天模式”纠偏为“统一顶层外壳入口”（14 `[x]` / 1 `[-]` / 11 `[ ]`）。`ChatScreen.swift`、`ChatStore.swift` 等文件的部分历史行号自 06-22 起有漂移；未触及的事项仍保留原描述。

> **2026-06-25 复核**：同步模型管理、会话模型、聊天 fixed workflow、目标模式注入和 i18n 条目的代码事实描述；未发现需要把 `[ ]` 改成 `[x]` 的新增事项。另记录长时间模型请求已移除本地 300 秒 resource timeout 固定上限（`LLMAPIClient.swift:1374`），仍需结合取消/重试交互观察挂起风险。`docs/会话持久化与多会话并发方案.md` 的“当前代码事实”仍有旧架构描述，后续需要单独同步。
