# PalmiAgent Agent Runtime Reliability Implementation Plan

> **2026-07-13 验证规则更新：** 下文中的 Simulator 内容仅保留为 2026-07-10 的历史记录，不再是可执行验收方案。此后所有 XCTest、UI 测试、App 启动与设备运行验证必须仅使用 **device-hub**；device-hub 不可用时只能做 generic iOS 编译、`build-for-testing` 编译产物检查和静态检查，且不得宣称运行测试通过。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 完成可靠单 Agent 运行时、稳定缓存前缀、可恢复 journal/checkpoint 和 iOS 26 后台延续，并提交到本地 `main`。

**Architecture:** 保留 `ChatStore.activeRuns` 与既有 Swift native tools，按纵向切片加入严格 SSE 终态、真实 Task 所有权、硬预算、专用执行 actor、稳定上下文顺序和 append-only journal。BGContinuedProcessingTask 只增强存活时间，所有恢复正确性来自本地 checkpoint。

**Tech Stack:** Swift 5、Swift Concurrency、XCTest、URLSession、CoreLocation、Vision、BackgroundTasks、Xcode 26.1。

## 执行状态（2026-07-10）

本计划的代码切片已经实现，并通过以下验收：`PalmiAgentTests` 34/34、Debug generic iOS build、Release generic iOS build，以及指定的 iPhone 17 Pro Simulator 构建/安装/启动和锁屏恢复。下方 checkbox 保留为最初的逐步执行清单，不作为最终验收状态来源。

本轮没有宣称完成实体设备上的 CPython/GIL、Location、OCR 或系统强杀验证；Python 仍按设计保留原串行语义。用户最终指定的运行目标是已启动的 iPhone 17 Pro Simulator。

---

## 文件结构

- `PalmiAgentTests/`: 正式 iOS unit-test target，按 Streaming/Runtime/Context/Persistence/Location 分组。
- `Core/Agent/AgentRunBudget.swift`: 纯预算策略与状态。
- `Core/Agent/AgentRunPersistence.swift`: journal/checkpoint/recovery 值类型。
- `Core/Agent/AgentRunPersistenceStore.swift`: actor 文件写入与 replay。
- `Core/Agent/AgentRuntimeTelemetry.swift`: 隐私安全的 request/prefix trace。
- `Infrastructure/ContinuedProcessingCoordinator.swift`: BackgroundTasks adapter。
- `Integrations/OCR/OCRRecognitionWorker.swift`: OCR 后台串行 worker。

### Task 1: 建立测试宿主

**Files:**
- Modify: `PalmiAgent.xcodeproj/project.pbxproj`
- Create: `PalmiAgent.xcodeproj/xcshareddata/xcschemes/PalmiAgent.xcscheme`
- Create: `PalmiAgentTests/TestTargetSmokeTests.swift`

- [x] 新增 `PalmiAgentTests` unit-test target，依赖 App target，并保留 app 的 signing、deployment 和依赖配置。
- [x] 新增 shared scheme Test action。
- [ ] 运行 `xcodebuild -list -project PalmiAgent.xcodeproj`，预期 targets 包含 `PalmiAgentTests`。
- [ ] 在 iOS 26.1 Simulator 运行 `TestTargetSmokeTests`，预期 1 test、0 failures。

### Task 2: 严格 SSE 终态

**Files:**
- Create: `PalmiAgentTests/Streaming/SSEEventDecoderTests.swift`
- Create: `PalmiAgent/Core/LLM/SSEEventDecoder.swift`
- Modify: `PalmiAgent/Integrations/Intelligence/LLMAPIClient.swift:1155-1520`

- [ ] 先写 RED：`data:` 无空格、comment、多 data 行、malformed payload、`[DONE]`、finish_reason、EOF-before-terminal。
- [ ] 运行 `-only-testing:PalmiAgentTests/SSEEventDecoderTests`，确认因 decoder/严格终态缺失而失败。
- [ ] 实现 `SSEEventDecoder.consume(line:)` 与 `finish()`，空行 dispatch，JSON 错误不静默吞掉。
- [ ] transport 记录 visible fragment 与 terminal；EOF-before-terminal 抛 typed incomplete error；仅 visible 前允许 retry。
- [ ] 重跑定向测试，预期 0 failures。

### Task 3: 运行所有权、取消与预算

**Files:**
- Create: `PalmiAgentTests/Runtime/AgentRunBudgetTests.swift`
- Create: `PalmiAgentTests/Runtime/AgentRunCancellationTests.swift`
- Create: `PalmiAgent/Core/Agent/AgentRunBudget.swift`
- Modify: `PalmiAgent/Core/Agent/AgentRunProfile.swift`
- Modify: `PalmiAgent/Core/Agent/AgentLoop.swift:378-1149,1296-1320,1398-1418`
- Modify: `PalmiAgent/Features/Chat/ChatStore.swift:160-169,437-594`
- Modify: `PalmiAgent/Features/Chat/ChatScreen.swift:1313-1332,3128-3153`
- Modify: localized strings for stop/interrupted text.

- [ ] 先写 RED：预算边界、模型请求 +1、工具数量 +1、elapsed 超限、取消 suspended operation。
- [ ] 实现纯 `AgentRunBudget`/`AgentRunBudgetState`，使用注入的 monotonic nanoseconds。
- [ ] 让 `ActiveRun` 持有真实 `runTask`，实现 `stopDisplayedRun()`，停止按钮在运行时可用。
- [ ] 在模型、工具 batch、审批边界检查 cancellation 和预算；审批取消 exactly-once 恢复 continuation。
- [ ] `ActionExecutor` 遇到 `CancellationError` 必须重新抛出，其他工具错误仍转业务 outcome。
- [ ] 运行 Runtime 定向测试和全量测试。

### Task 4: Location 与同步重活隔离

**Files:**
- Create: `PalmiAgentTests/Location/LocationRequestBrokerTests.swift`
- Create: `PalmiAgent/Integrations/Location/LocationRequestBroker.swift`
- Modify: `PalmiAgent/Integrations/Location/LocationService.swift:28-32,270-313`
- Create: `PalmiAgent/Integrations/OCR/OCRRecognitionWorker.swift`
- Modify: `PalmiAgent/Integrations/OCR/PPocrv6TinyOCRService.swift:35-126`
- Modify: `PalmiAgent/Core/Agent/AgentLoop.swift:1296-1320`

- [ ] 先写 RED：两个并发 waiter 都完成、取消一个不影响另一个、error 广播、start 只调用一次。
- [ ] 实现 waiter dictionary broker 和单次 in-flight 请求。
- [ ] 移除 parallel read-only task group 的显式 `@MainActor` child；保证执行器的 UI/System API 自行 hop MainActor。
- [ ] OCR 输入路径在 MainActor 固化为 URL，Data/Vision 工作交给 worker actor。
- [ ] Python 只在 CPython 串行/GIL 测试可执行后迁移；否则保留现状并记录未签收项，不用 detached 粗包。
- [ ] 运行 Location/OCR 测试与 app build。

### Task 5: 稳定缓存前缀与 provider adapter

**Files:**
- Create: `PalmiAgentTests/Context/ContextAssemblerCacheTests.swift`
- Create: `PalmiAgentTests/Context/PromptCacheStrategyTests.swift`
- Modify: `PalmiAgent/Core/Agent/ContextAssembler.swift:17-63`
- Modify: `PalmiAgent/Core/Agent/ContextLayerManager.swift:40-112`
- Modify: `PalmiAgent/Core/LLM/AgentModelRuntime.swift`
- Modify: `PalmiAgent/Core/LLM/LLMProviderRuntime.swift:44-75,109-153,225-260`
- Modify: `PalmiAgent/Integrations/Intelligence/OpenAICompatibleAgentTransport.swift:3-67`
- Modify: `PalmiAgent/Integrations/Intelligence/LLMAPIClient.swift:30-70,119-543,959-1015`
- Create: `PalmiAgent/Core/Agent/AgentRuntimeTelemetry.swift`

- [ ] 先写 RED：research/task 改变时 stable LCP 仍覆盖 system、未变 summary 和全部历史；OpenAI 有 key，DeepSeek/GLM/custom 无未知 key。
- [ ] 拆分 stable summary 与 volatile state，按 `system -> summary -> history -> volatile` 组装。
- [ ] 在 Agent request 增加 cache affinity，AgentLoop 使用 thread ID；wire adapter 只对 `.openai` 编码 `prompt_cache_key`。
- [ ] 增加逐 message/cumulative hash、first divergence 和 usage trace；日志不含正文、URL 或 key。
- [ ] 运行 Context/Cache 定向测试。

### Task 6: Journal、checkpoint、草稿与恢复

**Files:**
- Create: `PalmiAgentTests/Persistence/AgentRunPersistenceTests.swift`
- Create: `PalmiAgent/Core/Agent/AgentRunPersistence.swift`
- Create: `PalmiAgent/Core/Agent/AgentRunPersistenceStore.swift`
- Modify: `PalmiAgent/Core/Agent/AgentRunLedger.swift`
- Modify: `PalmiAgent/Core/Agent/AgentModels.swift:316-355`
- Modify: `PalmiAgent/Core/Agent/AgentLoop.swift`
- Modify: `PalmiAgent/Features/Chat/ChatStore.swift:247-256,1112-1202,1391-1665`
- Modify: `PalmiAgent/Core/Sandbox/WorkspaceManager.swift:683-735,900-909,1259-1285`

- [ ] 先写 RED：sequence 连续、重复/缺口、损坏尾、draft partial、tool intent 未完成、approval、terminal replay。
- [ ] 实现 Codable journal records 和纯 recovery reducer。
- [ ] 实现 actor store，稳定事件 append-only，draft 按 0.5–1 秒或 4KB 合并，terminal 强制 flush。
- [ ] AgentLoop 产生 model/tool/approval checkpoint，ChatStore 按 run sequence 串行写入。
- [ ] 冷启动以 journal 收敛 ledger/chat：partial 保留，未知副作用标记 requiresUserDecision，绝不自动重放。
- [ ] 后台会话不再每个 delta load/rewrite 整份 chat JSON。
- [ ] 运行 Persistence 测试和 crash fixture。

### Task 7: iOS 26 continued processing

**Files:**
- Create: `PalmiAgentTests/Lifecycle/ContinuedProcessingCoordinatorTests.swift`
- Create: `PalmiAgent/Infrastructure/ContinuedProcessingCoordinator.swift`
- Modify: `PalmiAgent/Infrastructure/AppContainer.swift`
- Modify: `PalmiAgent/Features/Chat/ChatStore.swift`
- Modify: `PalmiAgent/PalmiAgentApp.swift`
- Modify: `PalmiAgent/Info.plist`

- [ ] 先写 fake scheduler RED：submit failure 不影响 local run、progress 单调、complete once、expiration checkpoint-before-cancel。
- [ ] 实现 `BGTaskScheduler` adapter，identifier 使用 `com.hongyupeng.PalmiAgent.agent-run.*` permitted wildcard。
- [ ] 发送时动态 register/submit，完成时结束 system task；expiration 先 flush journal，再取消 run。
- [ ] 保留普通 background task 仅用于短暂 flush，不创建 background URLSession SSE。
- [ ] 运行 Lifecycle 测试、Debug/Release build。

### Task 8: 完整验证、裁判与提交

**Files:**
- Review all actual diff against the approved contracts.

- [ ] 运行 `git diff --check`。
- [ ] 运行所有 `PalmiAgentTests`，确认 0 failures。
- [ ] 运行 Debug 与 Release generic iOS build。
- [ ] 在可用真机验证锁屏、expiration、强杀恢复、Location、OCR、Python；不能执行的项目必须保持未完成状态，不能宣称签收。
- [ ] 由权限、行为、架构三个独立裁判全部输出 APPROVE。
- [ ] 将批准的纵向切片提交到本地 `main`；运行 `git status --short` 和 `git log -n`；不执行 push。

## 计划自审

- 设计中的每一项都有对应 Task。
- 没有 TBD/TODO 或未定义的“稍后处理”步骤。
- 类型职责和文件位置在各 Task 中一致。
- Python 明确需要专项签收，未用不安全 fallback 冒充完成。
