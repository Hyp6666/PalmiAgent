# 上游 API 协议选择设计

## 概述

PalmiAgent 将把自定义模型连接当前隐式的双协议行为，改造成明确的“上游 API 格式”偏好设置。添加模型页面只新增一行高级设置和一个协议选择弹窗。现有的模型获取、批量导入、手填模型 ID、别名、全局模型库和模型方案流程保持不变。

运行时将支持三种线上协议：

- OpenAI Responses
- OpenAI Chat Completions
- Anthropic Messages

用户配置还包含第四个选项“自动”。“自动”是一套有边界的协议协商策略，不是一种真正的线上协议。

## 目标

1. 允许用户把自定义上游连接明确锁定为 Responses、Chat Completions 或 Messages。
2. 保留“自动”模式，并且不依赖供应商或模型名称白名单。
3. 加入完整的 Anthropic Messages 请求、响应、流式传输和 Palmi 本地工具适配。
4. 让模型获取同时理解 OpenAI 风格和 Anthropic 风格的 Models API，并始终保留手动填写模型的能力。
5. 让普通聊天、Agent 工具调用、流式请求、候选模型验证和连接验证共用同一套协议决策。
6. 严格区分协议错误、鉴权错误、模型错误、参数错误和工具结构错误。

## 不在本次范围内

1. 不增加供应商预设或模型名称启发式规则。
2. 不增加可见的自定义 Models URL、鉴权方式选择器或协议专属参数编辑器。
3. 本次不启用供应商托管的联网搜索、代码执行、文件搜索或其他服务端工具。服务端工具仍属于独立的能力层，不得伪装成 Palmi 本地 function tool。
4. 不重新设计模型方案、全局模型库或模型获取/导入界面。

## 当前实现

`LLMWireProtocol` 目前只有 `responses` 和 `chatCompletions`。`OpenAICompatibleEndpointResolver` 只识别 `/responses` 和 `/chat/completions`。用户填写 Base URL 时，“自动”会先尝试 Responses，并在少数明确表示端点不受支持的状态码下回退到 Chat Completions。成功结果会按配置 ID、端点指纹和不透明模型 ID 隔离缓存 24 小时。

模型获取目前尝试 `/v1/models` 和 `/models`，可选发送 Bearer Token，并按较宽松的 OpenAI 风格 `data` 数组解码。它尚未支持 Anthropic 请求头和分页。

当前还有多条执行路径直接构造 Chat 或 Responses 请求。因此，仅给枚举增加一个 case 会造成不同调用链行为不一致，必须同时统一路由。

## 用户界面

### 添加模型

添加模型表单的连接区域按以下顺序显示：

1. `API 请求地址`
2. `API 密钥`
3. `高级设置`，右侧显示当前选择

地址标题及相关辅助功能文本不再使用“OpenAI 兼容”这种表述。

点击“高级设置”后，弹出原生选择页，其中只有一个单选区域，标题为 `上游 API 格式`：

- `自动`——默认并推荐
- `OpenAI Responses`
- `OpenAI Chat Completions`
- `Anthropic Messages`

当前选项显示勾选标记。选择结果保存在添加模型草稿中，弹窗按照现有导航规范关闭。

“高级设置”下方的区域在外观和行为上全部保持不变：

- 获取模型
- 选择并导入已发现模型
- 手填模型 ID
- 可选别名
- 添加模型

### 编辑模型

现有模型编辑页面增加同样的“高级设置”入口和选择弹窗。旧连接迁移后显示为“自动”。

## 配置数据模型

引入两个职责不同的枚举：

```swift
enum LLMWireProtocolPreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case responses
    case chatCompletions
    case anthropicMessages
}

enum LLMWireProtocol: String, Codable, Sendable, Hashable {
    case responses
    case chatCompletions
    case anthropicMessages
}
```

`ModelAPIConnectionRecord` 除现有端点数据外，还要保存协议偏好和派生后的 Messages URL。协议偏好属于连接，因为一次添加或导入操作会把所选上游格式应用到本次导入的所有模型；“自动”的最终协议判断仍然按具体模型隔离。

连接去重标识由规范化请求地址、API 密钥值和协议偏好共同组成。地址和密钥相同、但明确协议不同的两个连接不得合并。

旧记录缺少该字段时按 `.automatic` 解码。连接地址或协议偏好发生变化时，清除该连接已有的协议缓存和鉴权方式缓存。

## 端点解析

解析器规范化 HTTP(S) 地址，并识别以下结尾资源路径：

- `/responses`
- `/chat/completions`
- `/messages`

解析器从资源根路径派生以下端点：

- `responsesURL`
- `chatCompletionsURL`
- `anthropicMessagesURL`
- Models 端点候选列表

解析规则如下：

1. “自动”加完整资源地址时，按照地址后缀锁定对应协议。
2. 明确协议加 Base URL 时，派生并使用该协议的端点。
3. 明确协议加匹配的完整资源地址时，原样使用该地址。
4. 明确协议与完整资源地址发生冲突时，验证失败并显示本地化的“地址与协议不匹配”错误。
5. 对于需要派生推理端点的地址，查询参数和 URL fragment 继续视为无效输入。

## 运行时协议选择

所有推理入口在编码请求之前，统一调用同一个协议选择器。

### 明确选择协议

用户明确选择的协议具有最高优先级。Palmi 只发送对应的线上格式，不回退到其他推理协议。

### 自动选择协议

对于没有协议后缀的 Base URL，“自动”按照以下固定顺序执行：

1. 查找与当前连接、端点指纹和不透明模型 ID 完全匹配且未过期的成功缓存。
2. 尝试 Responses。
3. 只有当 Responses 在尚未接收任何有效响应内容前返回 HTTP 404、405、415 或 501，才尝试 Chat Completions。
4. 只有当 Chat Completions 同样在尚未接收有效响应内容前返回上述状态码，才尝试 Anthropic Messages。

以下情况绝不切换协议：

- HTTP 400、401、403、409、422 或 429
- 未知模型错误
- 可选推理参数被拒绝
- 工具名称无效或命中保留名称
- 工具 Schema 不受支持
- 限流或临时传输错误
- 流中已经出现有效协议事件或用户可见内容
- 无法识别的 HTTP 2xx 响应体，因为上游可能已经生成内容并产生费用

如果 2xx 响应体或 SSE 流能够明确识别为另一种已支持协议，Palmi 直接按照实际格式解码，不重新发送请求，并记录观察到的协议。如果完全无法识别，则返回响应格式错误，不重放请求。

只有成功解码有效响应信封或有效流事件后，才记录协议成功缓存。“自动”缓存 24 小时后失效，并按连接、端点指纹和模型 ID 严格隔离。

## 鉴权配置

Responses 和 Chat Completions 使用 `Authorization: Bearer <key>`。

Messages 使用：

- `x-api-key: <key>`
- `anthropic-version: 2023-06-01`
- `content-type: application/json`

对于使用 Messages 数据格式、但不接受标准 `x-api-key` 的兼容网关，如果请求在生成开始前返回 401 或 403，Palmi 可以使用 Bearer 鉴权在同一 Messages 协议内重试一次。鉴权回退不能改变推理协议。成功的鉴权方式按连接缓存，并在地址或密钥变化时清除。

## Anthropic Messages 适配器

适配器接收 Palmi 内部统一的消息、图片、推理和工具结构，生成 Anthropic Messages 请求。

### 请求转换

- System 和 developer 文本转换为顶层 `system`。
- 用户文本转换为 user text content block。
- 助手文本转换为 assistant text content block。
- 图片转换为带媒体类型的 base64 image source block。
- Palmi 本地工具定义转换为 `{name, description, input_schema}`。
- 助手发起的本地工具调用转换为 `tool_use` block。
- 工具结果转换为 user message 内的 `tool_result` block，并紧跟对应的 assistant tool-use 轮次。
- 工具选择转换为 Anthropic 的 `auto`、`any`、`none` 或指定工具形式。
- `stream` 由调用方当前请求模式决定。
- 没有可信模型元数据提供更低上限时，`max_tokens` 默认使用 4096。

第一版不会主动向未知自定义模型发送 Anthropic 原生 thinking 控制参数。适配器会解析上游返回的 thinking block，并且只允许在现有的“连接、端点、模型、线上协议”作用域内回放。未来若增加原生 thinking 控制，必须有明确的集成元数据，并复用现有的可选参数拒绝机制。

### 响应转换

非流式 JSON 和 SSE 事件统一转换到现有内部结果：

- `text` block → 助手正文
- `thinking` 和 `redacted_thinking` block → 原生推理数据
- `tool_use` block → `AgentToolUse`
- `input_tokens`、`output_tokens` 和缓存 token 字段 → `AgentModelTokenUsage`
- Anthropic stop reason → Palmi 的完成、工具调用或长度上限状态
- Anthropic error envelope → 统一服务错误模型

流解码器处理 message start、content-block start、content delta、content-block stop、message delta、message stop、ping 和 error 事件。工具 JSON 增量先按 content-block index 累积，完成后再解码。

## 模型获取

模型获取与推理协议选择彼此独立。成功读取 OpenAI 风格的 `/models` 响应，不能证明推理协议是 Chat Completions 或 Responses；读取到 Anthropic 风格列表，也不能覆盖用户明确选择的推理协议。

### 端点候选

解析器先移除已识别的完整推理端点后缀，再得到 API 资源根路径。随后按照有限且基于标准的顺序尝试现有候选：

1. `<resource-root>/models`
2. 输入只有域名和端口时，尝试 `/v1/models`
3. 输入只有域名和端口时，再尝试 `/models`

不引入供应商名称或模型名称路径表。

### 请求方式

- 选择 Responses 或 Chat：优先使用 OpenAI Bearer 鉴权。
- 选择 Messages：优先使用 Anthropic 请求头；只有鉴权或方法证据明确且重试安全时，再尝试 Bearer。
- 选择“自动”：先尝试 OpenAI 请求方式，再尝试 Anthropic 请求方式；模型获取成功不会直接决定推理协议。

### 响应解码

解码器接收 `data` 数组，在不知道供应商身份的情况下提取公共字段：

- `id`
- `display_name`、`displayName` 或 `name`
- 存在时读取 `owned_by`
- 存在时读取可选能力元数据

Anthropic 分页按照 `has_more` 和 `last_id`，使用 `after_id` 继续请求，并加入去重、有限页数上限和任务取消检查。OpenAI 风格的不分页列表继续正常工作。

模型获取错误规则保持清晰：

- 兼容鉴权方式均尝试后仍返回 401/403 → 鉴权错误
- 所有候选端点都返回 404/405/501 → 上游不支持模型列表
- 有效但为空的 `data` → 空模型列表
- 2xx 但 JSON 格式无效 → 响应格式错误

模型获取失败不能使推理连接失效，也不能移除手填模型入口。

## 工具命名空间与服务端工具

Palmi 本地工具继续使用稳定的内部标准名称。每个线上协议适配器在发送工具定义、工具调用和历史记录前，都通过可逆的安全名称编码器转换；收到结果后再映射回内部名称。

该编码器必须防止 Palmi 本地 function 占用 `web_search` 等协议保留的服务端工具名称。用户界面仍显示“Palmi Web Search”等易读标题；线上标识保持 ASCII 安全且不与协议保留名称冲突。

供应商托管工具是结构不同的协议对象。它们不能被放进本地 function 定义，也不能交给 Palmi 本地 `ToolRouter` 执行。本次改动只为未来的服务端工具注册表保留类型化适配边界，不实际启用服务端工具。

## 统一请求路由

以下调用路径必须共用同一个已解析协议和适配器注册表：

- 非流式模型调用
- 流式聊天
- 流式 Agent 工具调用
- 隐藏工作器与上下文压缩调用
- 候选模型验证
- API 连接验证
- Subagent 模型调用

协议选择器返回 Responses 或 Messages 后，任何调用路径都不得继续直接假设 Chat Completions。原生推理历史按最终线上协议隔离，禁止跨协议回放 reasoning block。

## 错误处理

决定是否重试之前，先把错误归入以下类别：

1. 传输或临时错误
2. 鉴权或授权错误
3. 端点或 HTTP 方法不受支持
4. 未知模型
5. 可选控制参数被拒绝
6. 工具名称或 Schema 被拒绝
7. 协议响应格式不匹配
8. 上游生成失败

只有第 3 类错误可以让“自动”进入下一个线上协议。可选参数重试必须留在原协议内。工具名称错误也必须留在原协议内，并在错误信息中显示对应的 Palmi 标准工具。

## 数据迁移

1. 协议偏好字段不存在时按“自动”解码。
2. 下次保存连接时派生并持久化 Messages URL，同时继续兼容旧归档。
3. 保留现有模型 ID、别名、验证状态、模型方案归属和已选择槽位。
4. 升级协议缓存 storage key 版本，使旧的双协议缓存自动失效。
5. API 密钥继续只存放在现有 Keychain 中，不迁移或暴露到其他位置。

## 测试策略

所有生产代码改动前先编写失败测试，覆盖：

1. 协议偏好的 Codable 迁移和连接去重标识。
2. Base URL 及三种完整端点后缀的地址派生。
3. 明确协议锁定和协议/地址冲突拒绝。
4. 自动尝试顺序、有限回退状态码、鉴权/工具/参数错误不回退，以及 2xx 或流开始后不重放。
5. 协议缓存的隔离、过期和失效。
6. Messages 鉴权选择和安全的 Bearer 兼容重试。
7. Messages 文本、图片、工具、工具结果和工具选择的 JSON 请求转换。
8. Messages 非流式与 SSE 解码，包括分片工具 JSON 和 usage。
9. OpenAI 与 Anthropic 模型获取、鉴权方式、分页、端点回退及不影响手填模型的错误。
10. 现有 Responses 和 Chat 请求行为的回归测试。
11. 添加/编辑模型的协议选择、旧配置显示为“自动”，以及模型获取和手填区域保持不变。
12. 聚焦测试通过后运行完整 App 测试套件和模拟器构建。

## 验收标准

1. 用户可以在添加和编辑模型页面的“高级设置”中看到并选择自动、Responses、Chat Completions 或 Messages。
2. 旧配置以“自动”加载，模型和方案数据不丢失。
3. 明确选择协议后，绝不静默切换到其他推理协议。
4. “自动”只依据有限且明确的端点不支持证据协商协议，并按模型缓存有效结果。
5. Messages 的流式文本和 Palmi 本地工具调用可以端到端工作。
6. OpenAI 风格和 Anthropic 风格模型列表都能进入现有且不变的模型选择界面。
7. 上游缺少 Models API 时，用户仍能手填模型。
8. Palmi 本地工具的保留名称不会原样作为服务端工具标识发送。
9. 普通聊天、Agent 执行、连接验证和 Subagent 对最终协议的判断保持一致。

## 协议参考资料

- OpenAI Models API：https://developers.openai.com/api/reference/resources/models/methods/list
- Anthropic API 概览：https://platform.claude.com/docs/en/api/overview
- Anthropic Models API：https://platform.claude.com/docs/en/api/models/list
