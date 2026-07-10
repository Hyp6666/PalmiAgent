# PalmiAgent 端侧 Agent 可靠运行时设计

## 目标

在不引入服务器、MCP、多 Agent 或新三方依赖的前提下，完成两个阶段：

1. 让单 Agent 的模型流、工具执行、取消、预算、并发和可观测性具备确定语义。
2. 让缓存前缀、运行日志、草稿 checkpoint、冷启动恢复和 iOS 26 后台延续形成闭环。

最终效果不是承诺 iOS 进程永久存活，而是保证：截断不会伪装成成功；用户可以停止；运行不会无限循环；已显示对话尽量不丢；未知副作用不会被自动重放；冷启动可以解释上次运行停在哪个安全边界。

## 非目标

- 不实现 MCP、subagent、多 Agent、服务端 runner。
- 不升级依赖，不重写全部 `WorkspaceManager`，不改变工具权限策略。
- 不向未知 OpenAI-compatible provider 发送未经声明的缓存字段。
- 不使用更多 retry 或更长 timeout 掩盖阻塞。
- 不把 `Task.detached` 当作解除 MainActor 的通用方案。

## 架构

### 1. 运行所有权与预算

`ChatStore.activeRuns` 继续作为会话运行 registry。每个 `ActiveRun` 必须拥有真实 `runTask`，并暴露停止操作。取消沿 Task 树传递到模型、工具和审批等待。

`AgentRunBudget` 是不可变策略，`AgentRunBudgetState` 记录模型请求、工具调用、循环次数和单调时钟起点。每次模型请求前、工具 batch 前后和审批前检查预算；超过预算产生明确 budget-stop，而不是继续循环或转成成功答复。

### 2. 流式协议

SSE 解码分为两层：

- `SSEEventDecoder` 负责 SSE 行语法、注释、空行和多 `data:` 字段。
- transport accumulator 负责 OpenAI JSON chunk、正文/reasoning/tool-call 分片、usage 和 terminal。

成功终态只能来自 `[DONE]` 或非空 `finish_reason`。JSON 损坏是协议错误；EOF-before-terminal 是 incomplete stream。首个可见 delta 前允许策略化 retry；出现任何正文、reasoning 或 tool fragment 后禁止自动重放。

### 3. 执行隔离

只移动已经证明会同步占用 MainActor 的工作：

- persistence writer 使用专用 actor，按 selection 和 sequence 串行。
- OCR 的 Data/Vision 识别放到专用 worker。
- Python 保持串行语义，只有完成 CPython 初始化/GIL/真机验证后才从 MainActor 迁移。
- 并行只读工具不再显式创建 `@MainActor` 子任务；写工具仍由项目/路径协调器限制。

定位请求使用 waiter broker 合并同一轮 `CLLocationManager.requestLocation()`，每个调用者拥有独立 continuation 和取消语义。

### 4. 稳定缓存前缀

专业模式消息顺序固定为：

```text
system -> hidden summary -> append-only stable history -> volatile research/task snapshot
```

`hidden summary` 代表被压缩的最早历史，只在压缩边界变化；research/task 是当前状态投影，必须位于稳定历史之后。OpenAI 官方 provider 使用 thread-scoped `prompt_cache_key`；DeepSeek/GLM 继续使用自动精确前缀缓存；custom/local 不增加未知 wire 字段。

诊断只记录 request/thread/provider/model、逐消息 hash、累计 hash、首个分歧 index、token 数和 usage，不记录正文、URL、API key。

### 5. Journal、checkpoint 与恢复

旧有 chat/session/ledger 继续作为 UI materialized projection。新增 append-only journal 作为运行事实记录，事件至少覆盖：

- run/model 开始与完整响应
- stream draft checkpoint
- tool intent/start/completed
- approval requested/resolved
- completed/interrupted/failed

每条记录包含 schema version、run ID、单调 sequence 和时间。稳定 checkpoint 在模型请求前、完整响应后、工具前后和审批边界落盘。草稿按时间/大小合并写，终态强制 flush。

恢复 reducer 只接受连续、合法的事件前缀：

- 完成的只读工具结果可复用。
- 存在副作用 tool intent/start 但没有 completed 时标记 `requiresUserDecision`，绝不自动重放。
- 半截流恢复为 partial/interrupted，不得 completed。
- waiting approval 恢复为明确等待或安全中断状态。

### 6. iOS 后台

发送操作可注册并提交 `BGContinuedProcessingTaskRequest`。它只是额外执行机会，不是正确性来源：提交失败不影响前台运行；progress 单调更新；expiration 严格执行 checkpoint、取消 run、完成系统 task。普通 `beginBackgroundTask` 只用于短暂 flush。

## 错误语义

- 用户停止、系统 expiration、预算停止：`interrupted`，不是普通失败。
- SSE malformed：协议失败，保留已经 checkpoint 的 partial draft。
- EOF-before-terminal：incomplete/interrupted，禁止提交为最终答复。
- 工具副作用状态未知：需要用户确认，禁止自动 retry。
- BG 调度不可用：记录能力缺失，前台 run 继续。

## 验证

- XCTest 覆盖 SSE、预算、取消、Location broker、缓存 LCP、journal/recovery 和 BG fake scheduler。
- Debug/Release generic iOS build。
- iOS 26.1 Simulator 全量测试。
- 可用真机时覆盖锁屏、后台、expiration、断网、强杀、Location、OCR 和 Python。

## 设计自审

- 无 TBD/TODO。
- BG 不承担持久化正确性。
- 缓存 summary 与 volatile state 已明确拆分。
- 非幂等工具没有自动重放路径。
- 本轮没有扩展到 MCP、多 Agent 或服务端。
