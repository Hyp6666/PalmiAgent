# PalmiAgent - Agent Loop 设计文档

> 日期：2026-04-13  
> 状态：待实现  
> 参考：[claw-code-main](https://github.com/instructkr/claw-code) (Rust runtime)

---

## 1. 目标

将 PalmiAgent 从 **单轮工具调用**（用户 → LLM → 1 个工具 → 最终回复）升级为 **完整的 Agent 循环**，支持：

1. **多轮持久循环** — LLM 可以连续调用多个工具，直到任务完成
2. **自动规划** — Agent 按需生成 plan/task，拆解复杂任务
3. **用户中途插入** — 对话进行中用户可以随时注入新 prompt
4. **交互式提问** — Agent 可以暂停并向用户提问（自由文本或选项列表）

---

## 2. 架构总览

### 2.1 分层设计

```
┌─────────────────────────────────────────────────┐
│                   UI Layer                       │
│  ChatScreen (SwiftUI) ← ChatStore (ViewModel)   │
└────────────────────┬────────────────────────────┘
                     │ AgentEvent stream
┌────────────────────▼────────────────────────────┐
│               Agent Layer (新增)                  │
│  AgentLoop (状态机)  ←  AgentSession (对话状态)    │
│  ContextCompactor    ←  AgentConfiguration       │
└───────┬─────────────────────────┬───────────────┘
        │                         │
┌───────▼───────┐   ┌────────────▼────────────────┐
│  LLM Client   │   │     Tool Execution          │
│ (HTTP 传输层)  │   │  ActionExecutor (现有)       │
│  纯 API 调用   │   │  + Agent 内部工具 (新增)      │
└───────────────┘   └─────────────────────────────┘
```

### 2.2 与现有架构的关系

| 现有组件 | 变化 |
|---------|------|
| `LLMToolCallingService` | 拆分：API 传输逻辑提取为 `LLMAPIClient`，编排逻辑移入 `AgentLoop` |
| `ChatStore` | 调用 `AgentLoop` 替代直接调用 `LLMToolCallingService`；处理新事件类型 |
| `ChatMessage`/`ChatScreen` | 新增消息类型：plan 卡片、ask_user 卡片、task 进度卡片 |
| `ActionExecutor` | 不变，作为工具执行引擎被 `AgentLoop` 调用 |
| `ActionCatalog` | 不变，但 agent 内部工具单独注册，不走 catalog |
| `ManualLabStore` | 保留不变，仍为单轮调试模式 |

---

## 3. 核心模块设计

### 3.1 AgentSession — 对话状态

> 借鉴 claw-code `Session` + `ConversationMessage`

```swift
// Core/Agent/AgentSession.swift

struct AgentMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let role: AgentMessageRole
    let blocks: [AgentContentBlock]
    let usage: AgentTokenUsage?
    let timestamp: Date
}

enum AgentMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

enum AgentContentBlock: Codable, Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: String)
    case toolResult(toolUseID: String, toolName: String, output: String, isError: Bool)
}

struct AgentTokenUsage: Codable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
}

struct AgentSession: Codable, Sendable {
    let id: UUID
    var messages: [AgentMessage]
    var plan: AgentPlan?
    var cumulativeUsage: AgentTokenUsage

    mutating func append(_ message: AgentMessage) { ... }
}
```

**关键决策**：
- 消息模型独立于 OpenAI `ChatMessage`（后者是 API 传输格式），`AgentMessage` 是内部状态格式
- `LLMAPIClient` 负责 `AgentMessage` ↔ `ChatMessage` 的转换
- Session 可序列化，支持持久化到 workspace

### 3.2 AgentLoop — 状态机

> 借鉴 claw-code `ConversationRuntime.run_turn()`，但改造为异步状态机以支持用户中断和交互

```swift
// Core/Agent/AgentLoop.swift

enum AgentState: Sendable {
    case idle
    case thinking                           // LLM 正在生成
    case executing(tools: [PendingToolUse]) // 正在执行工具
    case waitingForUser(request: UserInputRequest)  // 等待用户输入
    case completed
    case failed(Error)
}

struct PendingToolUse: Sendable {
    let id: String
    let name: String
    let input: String
}

struct UserInputRequest: Identifiable, Sendable {
    let id: UUID
    let prompt: String
    let options: [UserInputOption]?  // nil = 自由文本
    let toolUseID: String            // 关联的 ask_user tool call ID
}

struct UserInputOption: Identifiable, Sendable {
    let id: String   // "1", "2", "3" 或自定义 key
    let label: String
    let description: String?
}

@MainActor
final class AgentLoop {
    private let apiClient: LLMAPIClient
    private let toolExecutor: AgentToolExecutor
    private let configuration: AgentConfiguration

    private(set) var session: AgentSession
    private(set) var state: AgentState = .idle

    // 事件流 — UI 层通过此流接收实时更新
    let events: AsyncStream<AgentEvent>
    private let eventContinuation: AsyncStream<AgentEvent>.Continuation

    // 用户输入队列 — 支持中途插入
    private var pendingUserInput: AsyncStream<String>
    private var userInputContinuation: AsyncStream<String>.Continuation
}
```

**核心循环伪代码**：

```swift
func runTurn(userInput: String) async {
    session.append(.user(text: userInput))
    var iterations = 0

    while true {
        // 检查安全阀
        iterations += 1
        guard iterations <= configuration.maxIterations else {
            emit(.maxIterationsReached)
            break
        }

        // 检查上下文是否需要压缩
        if shouldCompact() {
            let compacted = ContextCompactor.compact(session, config: configuration.compaction)
            session = compacted.session
            emit(.contextCompacted(removedCount: compacted.removedCount))
        }

        // 调用 LLM
        state = .thinking
        emit(.thinkingStarted)

        let response = try await apiClient.createChatCompletion(
            session: session,
            tools: allToolDefinitions()
        )

        let assistantMessage = response.toAgentMessage()
        session.append(assistantMessage)
        session.cumulativeUsage += response.usage

        // 提取 tool_use blocks
        let toolUses = assistantMessage.blocks.compactMap { block -> PendingToolUse? in
            if case .toolUse(let id, let name, let input) = block {
                return PendingToolUse(id: id, name: name, input: input)
            }
            return nil
        }

        // 无 tool call → 自然结束
        if toolUses.isEmpty {
            emit(.assistantReply(text: assistantMessage.textContent))
            state = .completed
            break
        }

        // 执行工具
        state = .executing(tools: toolUses)
        for toolUse in toolUses {
            emit(.toolStarted(toolUse))

            // 检查是否是 ask_user 工具
            if toolUse.name == "ask_user" {
                let request = parseUserInputRequest(toolUse)
                state = .waitingForUser(request: request)
                emit(.userInputRequested(request))

                // 暂停循环，等待用户回答
                let userResponse = await waitForUserInput()
                let resultMessage = AgentMessage.toolResult(
                    toolUseID: toolUse.id,
                    toolName: toolUse.name,
                    output: userResponse,
                    isError: false
                )
                session.append(resultMessage)
                emit(.toolFinished(toolUse, result: userResponse))
                continue
            }

            // 普通工具执行
            let (output, isError) = await toolExecutor.execute(toolUse)
            let resultMessage = AgentMessage.toolResult(
                toolUseID: toolUse.id,
                toolName: toolUse.name,
                output: output,
                isError: isError
            )
            session.append(resultMessage)
            emit(.toolFinished(toolUse, result: output))
        }

        // 所有工具执行完毕，继续循环（让 LLM 看到结果并决定下一步）
    }

    persistSession()
}
```

**用户中途插入**：

```swift
/// 用户在 agent 运行中发送新消息
func injectUserMessage(_ text: String) {
    // 将消息放入队列
    userInputContinuation.yield(text)

    // 如果当前正在等待用户输入 (ask_user)，直接作为回答
    // 如果当前正在 thinking/executing，设置中断标记
    // 下一次循环迭代时会检查中断，追加用户消息后继续
}
```

### 3.3 AgentEvent — 事件流

```swift
// Core/Agent/AgentEvent.swift

enum AgentEvent: Sendable {
    // 状态变化
    case thinkingStarted
    case assistantText(delta: String)           // 流式文本片段（预留）
    case assistantReply(text: String)           // 完整回复文本

    // 工具执行
    case toolStarted(PendingToolUse)
    case toolFinished(PendingToolUse, result: String)
    case toolError(PendingToolUse, error: String)

    // 用户交互
    case userInputRequested(UserInputRequest)
    case userInputReceived(String)

    // 计划管理
    case planCreated(AgentPlan)
    case planUpdated(AgentPlan)
    case taskStatusChanged(taskID: String, status: AgentTaskStatus)

    // 系统
    case contextCompacted(removedCount: Int)
    case maxIterationsReached
    case turnCompleted(iterations: Int, usage: AgentTokenUsage)
    case error(String)
}
```

### 3.4 Agent 内部工具

这些工具不在 `ActionCatalog` 中，而是 Agent 专属的元工具：

```swift
// Core/Agent/Tools/

// ── ask_user ──
// LLM 调用此工具向用户提问，循环暂停等待回答
struct AskUserToolDefinition {
    static let name = "ask_user"
    static let schema = ToolJSONSchema.object(
        properties: [
            "prompt": .string(description: "要问用户的问题"),
            "options": .array(
                description: "可选。选项列表，每个选项包含 id 和 label",
                items: .object(properties: [
                    "id": .string(description: "选项标识"),
                    "label": .string(description: "选项显示文本"),
                    "description": .string(description: "可选。选项详细说明")
                ], required: ["id", "label"])
            )
        ],
        required: ["prompt"]
    )
}

// ── create_plan ──
// LLM 在开始复杂任务前主动拆分步骤
struct CreatePlanToolDefinition {
    static let name = "create_plan"
    static let schema = ToolJSONSchema.object(
        properties: [
            "goal": .string(description: "总目标描述"),
            "tasks": .array(
                description: "任务列表",
                items: .object(properties: [
                    "id": .string(description: "任务唯一标识"),
                    "title": .string(description: "任务标题"),
                    "description": .string(description: "任务详细描述"),
                    "depends_on": .stringArray(description: "可选。依赖的任务 id 列表")
                ], required: ["id", "title"])
            )
        ],
        required: ["goal", "tasks"]
    )
}

// ── update_task ──
// LLM 完成某个 task 后更新状态
struct UpdateTaskToolDefinition {
    static let name = "update_task"
    static let schema = ToolJSONSchema.object(
        properties: [
            "task_id": .string(description: "要更新的任务 id"),
            "status": .string(description: "新状态", enumValues: ["in_progress", "completed", "failed", "skipped"]),
            "summary": .string(description: "可选。完成摘要或失败原因")
        ],
        required: ["task_id", "status"]
    )
}
```

**Plan 数据模型**：

```swift
struct AgentPlan: Codable, Sendable {
    let goal: String
    var tasks: [AgentTask]
}

struct AgentTask: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    let description: String?
    let dependsOn: [String]
    var status: AgentTaskStatus
    var summary: String?
}

enum AgentTaskStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case skipped
}
```

### 3.5 ContextCompactor — 上下文压缩

> 直接借鉴 claw-code `compact.rs` 的逻辑

```swift
// Core/Agent/ContextCompactor.swift

struct CompactionConfig: Sendable {
    let preserveRecentMessages: Int     // 默认 6
    let maxEstimatedTokens: Int         // 默认 10_000
}

struct CompactionResult {
    let compactedSession: AgentSession
    let summary: String
    let removedMessageCount: Int
}

enum ContextCompactor {

    static func shouldCompact(_ session: AgentSession, config: CompactionConfig) -> Bool {
        let start = compactedSummaryPrefixLength(session)
        let compactable = Array(session.messages[start...])
        return compactable.count > config.preserveRecentMessages
            && compactable.map(estimateTokens).reduce(0, +) >= config.maxEstimatedTokens
    }

    static func compact(_ session: AgentSession, config: CompactionConfig) -> CompactionResult {
        // 1. 找到已有的压缩摘要（如果有）
        // 2. 确定保留范围：保留最近 N 条消息
        // 3. 对被移除的消息生成摘要：
        //    - 消息统计（user/assistant/tool 各多少条）
        //    - 使用过的工具列表
        //    - 最近的用户请求（最多 3 条，截断到 160 字符）
        //    - 待办事项（包含 todo/next/pending 关键词的消息）
        //    - 当前工作（最近一条非空消息）
        //    - 时间线（每条消息的 role: 摘要）
        // 4. 如果已有旧摘要，合并为 "Previously compacted" + "Newly compacted"
        // 5. 构建新 session：[system(摘要)] + [保留的消息]
    }

    private static func summarizeMessages(_ messages: [AgentMessage]) -> String {
        // 借鉴 claw-code compact.rs summarize_messages()
        // 生成 <summary>...</summary> 格式的摘要文本
    }

    private static func estimateTokens(_ message: AgentMessage) -> Int {
        // 粗估：文本长度 / 4 + 1（每个 block）
    }
}
```

### 3.6 LLMAPIClient — 纯传输层

从现有 `LLMToolCallingService` 提取 HTTP 调用逻辑：

```swift
// Integrations/Intelligence/LLMAPIClient.swift

@MainActor
final class LLMAPIClient {
    private let apiConfigurationStore: APIConfigurationStore
    private let session: URLSession

    /// 将 AgentSession 转换为 OpenAI ChatMessage 格式并发送
    func createChatCompletion(
        providerID: APIProviderID,
        session: AgentSession,
        systemPrompt: [String],
        tools: [ChatToolDefinition]
    ) async throws -> LLMCompletionResponse {
        let configuration = try apiConfigurationStore.resolvedConfiguration(for: providerID)
        let messages = convertToAPIMessages(systemPrompt: systemPrompt, session: session)
        // ... HTTP POST（复用现有逻辑）
    }

    /// AgentMessage → ChatMessage 转换
    private func convertToAPIMessages(
        systemPrompt: [String],
        session: AgentSession
    ) -> [ChatMessage] {
        var messages: [ChatMessage] = [
            .system(systemPrompt.joined(separator: "\n\n"))
        ]
        for agentMessage in session.messages {
            switch agentMessage.role {
            case .system:
                // compaction 产生的 system 消息追加到 system prompt 后面
                messages.insert(.system(agentMessage.textContent), at: 1)
            case .user:
                messages.append(.user(agentMessage.textContent))
            case .assistant:
                messages.append(.assistant(
                    agentMessage.textContent,
                    toolCalls: agentMessage.toolCalls
                ))
            case .tool:
                if case .toolResult(let toolUseID, _, let output, _) = agentMessage.blocks.first {
                    messages.append(.tool(output, toolCallID: toolUseID))
                }
            }
        }
        return messages
    }
}
```

### 3.7 AgentConfiguration

```swift
// Core/Agent/AgentConfiguration.swift

struct AgentConfiguration: Sendable {
    let maxIterations: Int              // 单次 turn 最大循环次数，默认 30
    let maxTotalTokens: Int             // 单次 turn 最大 token 消耗，默认 50_000
    let compaction: CompactionConfig    // 上下文压缩配置
    let providerID: APIProviderID       // LLM 服务商

    static let `default` = AgentConfiguration(
        maxIterations: 30,
        maxTotalTokens: 50_000,
        compaction: CompactionConfig(
            preserveRecentMessages: 6,
            maxEstimatedTokens: 10_000
        ),
        providerID: .glm
    )
}
```

---

## 4. 状态机详细设计

```
┌─────────┐
│  idle    │◄──────────────────────────────────────┐
└────┬─────┘                                       │
     │ runTurn(userInput)                           │
     ▼                                             │
┌──────────┐  有 tool_use    ┌────────────┐        │
│ thinking │────────────────►│ executing  │        │
│          │                 │            │        │
└────┬──┬──┘◄────────────────┘────────────┘        │
     │  │    工具全部执行完                           │
     │  │                                          │
     │  │  tool_use 是 ask_user                     │
     │  ▼                                          │
     │ ┌────────────────┐                          │
     │ │ waitingForUser  │──── 用户回答 ──► thinking │
     │ └────────────────┘                          │
     │                                             │
     │  无 tool_use（自然结束）                       │
     ▼                                             │
┌───────────┐                                      │
│ completed │──── 用户发新消息 ────────────────────────┘
└───────────┘

任何状态 ──── 错误 ────► failed
任何状态 ──── 用户中途注入消息 ────► 设置中断标记，
    当前循环迭代结束后将新消息追加到 session，重新进入 thinking
```

### 中断机制

```swift
// 中断标记
private var interruptedWithMessage: String?

// 在循环每次迭代开始时检查
func checkForInterrupt() -> Bool {
    if let injectedMessage = interruptedWithMessage {
        interruptedWithMessage = nil
        session.append(.user(text: injectedMessage))
        emit(.userInputReceived(injectedMessage))
        return true // 继续循环，用新消息重新调 LLM
    }
    return false
}
```

---

## 5. 系统提示词设计

> 借鉴 claw-code 的分段式 system prompt 架构

### 5.1 提示词结构

```
┌────────────────────────────────────┐
│ Section 1: 身份与角色               │  ← 静态，可缓存
│ Section 2: 系统规则                 │  ← 静态
│ Section 3: 任务执行准则             │  ← 静态
│ Section 4: 行动安全准则             │  ← 静态
├────────────────────────────────────┤
│ === DYNAMIC BOUNDARY ===           │  ← 缓存分界线
├────────────────────────────────────┤
│ Section 5: 环境上下文               │  ← 每次会话动态生成
│ Section 6: 工具使用说明             │  ← 动态（当前可用工具数）
│ Section 7: Compaction 摘要          │  ← 仅压缩后出现
└────────────────────────────────────┘
```

### 5.2 各段内容

**Section 1 — 身份与角色**

```
你是 PalmiAgent，一个运行在真实 iOS 设备上的智能 Agent。
你拥有对用户手机系统能力的直接访问权限，包括日历、通讯录、相册、位置、通知、文件系统等。
你的目标是通过调用工具完成用户的请求。你可以连续多次调用工具、制定执行计划、在需要时向用户提问。
```

**Section 2 — 系统规则**（借鉴 claw-code `get_simple_system_section`）

```
# 系统规则
 - 你的所有文本输出都会直接展示给用户。
 - 工具调用需要经过权限检查。如果某个工具当前不可用，会返回错误结果。
 - 工具结果来自真实系统 API，可能包含大量数据。关注与任务相关的部分。
 - 如果上下文过长，系统会自动压缩早期消息。你会看到一条摘要。
 - 用中文与用户交流。
```

**Section 3 — 任务执行准则**（借鉴 claw-code `get_simple_doing_tasks_section`）

```
# 任务执行准则
 - 优先调用工具来完成任务，不要只解释应该怎么做。
 - 如果任务复杂，先调用 create_plan 制定计划，然后逐步执行。
 - 每完成一个子任务，调用 update_task 更新状态。
 - 如果需要用户提供信息或做出选择，调用 ask_user 工具。
 - 如果工具返回错误，先分析原因再决定下一步，不要盲目重试。
 - 如果当前工具集做不到用户的请求，直接告知，不要假装完成。
 - 任务完成后给出简洁的结果摘要。
```

**Section 4 — 行动安全准则**（借鉴 claw-code `get_actions_section`）

```
# 行动安全准则
 - 涉及发送消息（短信、邮件）、拨打电话、删除数据等不可逆操作时，先用 ask_user 征求用户确认。
 - 涉及创建日历事件、提醒等操作时，确认关键参数（时间、标题）正确后再执行。
 - 如果用户的指令模糊，用 ask_user 澄清，不要猜测。
```

**Section 5 — 环境上下文**（动态生成）

```
# 环境上下文
 - 设备：iOS {version}
 - 日期：{当前日期}
 - 可用工具数量：{count} 个系统工具 + 3 个 Agent 内部工具
 - 工作区：{workspace 路径，如果已创建}
```

**Section 6 — 工具使用说明**

```
# 工具说明
你有两类工具：

## Agent 内部工具（元工具）
 - ask_user: 向用户提问。支持自由文本和选项列表。调用后会暂停等待用户回答。
 - create_plan: 为复杂任务创建执行计划。包含 goal 和 tasks 列表。
 - update_task: 更新某个任务的状态和摘要。

## 系统能力工具
以下 {count} 个工具可直接操作 iOS 系统能力：
（工具列表由 ActionCatalog 动态注入）
```

### 5.3 System Prompt Builder

```swift
// Core/Agent/AgentPromptBuilder.swift

struct AgentPromptBuilder {
    let toolCount: Int
    let workspacePath: String?
    let currentDate: String
    let iosVersion: String

    func build() -> [String] {
        var sections: [String] = []
        sections.append(identitySection())
        sections.append(systemRulesSection())
        sections.append(taskGuidelinesSection())
        sections.append(actionSafetySection())
        // ── dynamic boundary ──
        sections.append(environmentSection())
        sections.append(toolUsageSection())
        return sections
    }

    func render() -> String {
        build().joined(separator: "\n\n")
    }
}
```

---

## 6. AgentToolExecutor — 统一工具执行

```swift
// Core/Agent/AgentToolExecutor.swift

@MainActor
final class AgentToolExecutor {
    private let actionExecutor: ActionExecutor       // 现有的 68 个系统工具
    private let actions: [ToolAction]                // 当前启用的工具列表
    private weak var agentLoop: AgentLoop?           // 反向引用，用于 plan 更新

    /// 执行工具，返回 (output, isError)
    func execute(_ toolUse: PendingToolUse) async -> (String, Bool) {
        switch toolUse.name {

        // ── Agent 内部工具 ──
        case "ask_user":
            // 由 AgentLoop 直接处理，不走这里
            return ("", false)

        case "create_plan":
            return handleCreatePlan(input: toolUse.input)

        case "update_task":
            return handleUpdateTask(input: toolUse.input)

        // ── 系统工具 ──
        default:
            guard let action = actions.first(where: { $0.id.rawValue == toolUse.name }) else {
                return ("未知工具：\(toolUse.name)", true)
            }
            do {
                let arguments = try ToolArguments(jsonString: toolUse.input)
                let outcome = await actionExecutor.execute(action, arguments: arguments)
                let payload = encodeToolResultPayload(action: action, outcome: outcome)
                return (payload, outcome.result.status == .failure)
            } catch {
                return ("工具参数解析失败：\(error.localizedDescription)", true)
            }
        }
    }
}
```

---

## 7. ChatStore 改造

### 7.1 接入 AgentLoop

```swift
// 改造后的 send() 方法

func send() {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // 如果 agent 正在等待用户输入（ask_user），作为回答注入
    if case .waitingForUser = agentLoop.state {
        agentLoop.injectUserMessage(text)
        appendUserMessage(text)
        inputText = ""
        return
    }

    // 如果 agent 正在运行（thinking/executing），作为中途插入
    if agentLoop.state != .idle && agentLoop.state != .completed {
        agentLoop.injectUserMessage(text)
        appendUserMessage(text)
        inputText = ""
        return
    }

    // 正常启动新 turn
    appendUserMessage(text)
    inputText = ""
    isLoading = true

    Task {
        await agentLoop.runTurn(userInput: text)
        isLoading = false
    }
}
```

### 7.2 事件处理

```swift
// 监听 AgentEvent 流

private func observeAgentEvents() {
    Task {
        for await event in agentLoop.events {
            switch event {
            case .thinkingStarted:
                appendAgentMessage(kind: .normal, content: "正在思考...")

            case .assistantReply(let text):
                appendAgentMessage(kind: .normal, content: text)

            case .toolStarted(let toolUse):
                appendRunningToolCard(toolUse)

            case .toolFinished(let toolUse, let result):
                finishToolCard(toolUse, result: result)

            case .userInputRequested(let request):
                appendAskUserCard(request)
                isLoading = false  // 允许用户输入

            case .planCreated(let plan):
                appendPlanCard(plan)

            case .taskStatusChanged(let taskID, let status):
                updatePlanCard(taskID: taskID, status: status)

            case .turnCompleted(let iterations, let usage):
                finalizeSession(iterations: iterations, usage: usage)
                isLoading = false

            case .error(let message):
                appendAgentMessage(kind: .summary, content: "错误：\(message)")
                isLoading = false

            // ... 其他事件
            }
        }
    }
}
```

### 7.3 新增 UI 消息类型

```swift
// PalmiChatMessage.Kind 扩展

enum Kind: String, Codable, Sendable {
    case normal
    case toolCall
    case summary
    case sessionHeader
    case askUser       // 新增：用户提问卡片
    case plan          // 新增：计划卡片
    case taskUpdate    // 新增：任务状态更新
}
```

---

## 8. 对话续接

用户在 `completed` 状态下发新消息时，Agent 不会创建新 session，而是在现有 session 上继续。这实现了多轮对话：

```
Turn 1: 用户 "帮我查一下今天的日程" → Agent 调用工具 → 完成
Turn 2: 用户 "把下午 3 点的会议改到 4 点" → Agent 在同一 session 继续 → 调用工具 → 完成
Turn 3: 用户 "再帮我创建一个明天的提醒" → 继续...
```

Session 持久化确保退出 app 后也能恢复：

```swift
// AgentSession 持久化
func persistSession() {
    try? workspaceManager.saveAgentSession(session)
}

func restoreSession() -> AgentSession? {
    try? workspaceManager.loadAgentSession()
}
```

---

## 9. 文件结构

```
PalmiAgent/
├─ Core/
│  ├─ Actions/              (现有，不变)
│  ├─ Configuration/        (现有，不变)
│  ├─ Sandbox/              (现有，不变)
│  └─ Agent/                ★ 新增
│     ├─ AgentSession.swift
│     ├─ AgentLoop.swift
│     ├─ AgentEvent.swift
│     ├─ AgentConfiguration.swift
│     ├─ AgentPromptBuilder.swift
│     ├─ AgentToolExecutor.swift
│     ├─ ContextCompactor.swift
│     └─ Models/
│        ├─ AgentMessage.swift
│        ├─ AgentPlan.swift
│        └─ UserInputRequest.swift
│
├─ Integrations/
│  └─ Intelligence/
│     ├─ LLMAPIClient.swift          ★ 新增（从 LLMToolCallingService 提取）
│     └─ LLMToolCallingService.swift  (保留，ManualLab 继续使用)
│
├─ Features/
│  └─ Chat/
│     ├─ ChatStore.swift              ★ 改造（接入 AgentLoop）
│     ├─ ChatScreen.swift             ★ 改造（新增卡片类型）
│     └─ ChatMessage.swift            ★ 改造（新增消息 Kind）
│
└─ Infrastructure/
   ├─ AppContainer.swift              ★ 改造（注入 AgentLoop 依赖）
   ├─ ActionExecutor.swift            (不变)
   └─ ActionCatalog.swift             (不变)
```

---

## 10. 实现顺序建议

| 阶段 | 内容 | 预估新增代码 |
|------|------|------------|
| **P0** | `AgentMessage` + `AgentSession` 数据模型 | ~150 行 |
| **P1** | `LLMAPIClient` 从 LLMToolCallingService 提取 | ~200 行 |
| **P2** | `AgentLoop` 基础循环（不含中断和 ask_user） | ~250 行 |
| **P3** | `AgentToolExecutor` + 内部工具注册 | ~150 行 |
| **P4** | `AgentPromptBuilder` 系统提示词 | ~100 行 |
| **P5** | `ChatStore` 改造 + AgentEvent 处理 | ~200 行 |
| **P6** | `ask_user` 工具 + `waitingForUser` 状态 | ~100 行 |
| **P7** | `create_plan` + `update_task` 工具 | ~150 行 |
| **P8** | `ContextCompactor` 上下文压缩 | ~200 行 |
| **P9** | 用户中途插入 + 中断机制 | ~100 行 |
| **P10** | Session 持久化 + 对话续接 | ~100 行 |
| **P11** | ChatScreen UI 改造（新卡片类型） | ~200 行 |

**总计约 1900 行新代码**，集中在 `Core/Agent/` 目录。

---

## 11. 未来扩展（本期不做）

- **流式输出**：`LLMAPIClient` 支持 SSE，`AgentLoop` 通过 `.assistantText(delta:)` 事件逐字推送
- **并行工具执行**：当 LLM 在一次回复中返回多个独立 tool_use 时，用 `TaskGroup` 并行执行
- **多 Provider 支持**：`AgentConfiguration` 允许配置不同的 LLM 服务商
- **Hook 系统**：类似 claw-code 的 pre/post tool execution hooks
- **权限策略**：per-tool 权限级别（auto-allow / ask-user / deny）
