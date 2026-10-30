# DeepSeek API 只读诊断（2026-10-30）

## 范围与证据边界

针对主代理提供的 DeviceHub Palmi 26.11 build 5 现象检查本地源码及 DeepSeek 官方资料。未操作 UI，未读取、复制、打印或发送任何实际 API Key，未修改应用代码、网络代理或安全设置。仅新增此报告。

主代理提供的现场事实：选择 DeepSeek 预设，地址 `https://api.deepseek.com`、Chat Completions；获取模型显示 `DeepSeek-V4.1-Flash` 与 `DeepSeek-V4-Pro`；选择 Flash 后文本和视觉检查均返回 `deepseek-flash：Custom API 调用失败：HTTP 401 Authentication Fails (governor)`。主代理已通过 UI 比较确认输入 Key 与用户提供内容一致。本报告没有独立复核 Key、设备网络请求或服务端账户状态。

## 结论

1. **当前选择的 Flash API ID 正确。** 官方首次调用页给出的 ID 为 `deepseek-flash`，现由 DeepSeek-V4.1-Flash-1017 提供服务；旧 `deepseek-v4-flash` 与 `deepseek-v4-flash-vision-exp` 仍作为兼容别名。用户口头简称 `dsv4flash` 不应作为 API ID 手填。现场已显示的 `deepseek-flash` 无需因模型名称再改动。[官方首次调用](https://api-docs.deepseek.com/en/)
2. **列表显示名称与调用 ID 并不冲突。** 官方 `/models` 示例正是 `id: deepseek-flash / name: DeepSeek-V4.1-Flash` 和 `id: deepseek-v4-pro / name: DeepSeek-V4-Pro`。Flash 支持 text/image，Pro 示例仅声明 text。本地导入保留 `id` 供请求使用，显示 `name`，没有把 Flash 改成 Pro。[官方模型列表](https://api-docs.deepseek.com/api/list-models/)
3. **401 当前只能确定为认证被拒绝，不能确定是哪一环节导致。** 官方错误码将 401 定义为 Key 认证失败；余额不足是 402，请求格式/参数是 400/422。`governor` 未在检查的官方错误码页或相关官方搜索结果中找到定义，不能将其解释为已证实的代理拦截、风控、限流或余额问题。[官方错误码](https://api-docs.deepseek.com/quick_start/error_codes/)
4. **源码未发现 Flash 模型映射或正常 Bearer 构造错误。** 模型库测试从当前编辑内容或已保存连接取得 Key，经冻结配置传递；请求头将两端空白去除后写为 `Authorization: Bearer <key>`，不存在读取旧 API 配置的旁路。`Custom API` 是模型库统一运行时 provider 的显示标题，不能据此判断请求去了错误服务。
5. **尚无已验证可用的 UI 修复。** 可以通过完整 Chat Completions 地址做一次单变量排除，但这只是隔离端点差异，不是已确诊修复。若仍为同一 401，继续改模型名、切视觉能力、改思考参数没有现有证据支持。

## 本地请求链路

| 环节 | 源码位置 | 已确认行为 |
| --- | --- | --- |
| DeepSeek 预设 | `PalmiAgent/Core/ModelLibrary/ModelLibraryStore+Editing.swift:37` | 基址为根地址；模型列表 `/models`；Chat `/chat/completions`；协议 Chat Completions |
| 获取模型 | `PalmiAgent/Features/Settings/ModelSettingsScreens.swift:519`、`PalmiAgent/Core/LLM/LLMModelDiscoveryService.swift:308` | 预设明确的 `/models` 发 GET；Chat 协议发送 Bearer；只解析返回列表，不实际调用模型 |
| 导入模型 | `PalmiAgent/Features/Settings/ModelEditingComponents.swift:310` | `providerModelID = model.id`；显示名另存，未改写 id |
| 文本/视觉检查 | `PalmiAgent/Features/Settings/ModelEditingComponents.swift:223` | 都用 ModelProbe；文本一句“Reply with OK only.”；视觉一张纯红 JPEG；无工具；思考关闭 |
| 冻结配置 | `PalmiAgent/Core/ModelLibrary/MainModelResolver.swift:150` | 直接使用传入的 Key 与模型 ID；统一 `.customOpenAI` provider |
| 配置解析 | `PalmiAgent/Integrations/Intelligence/LLMAPIClient.swift:1603` | 已解析 override 原样使用；无旧配置回退 |
| 认证头 | `PalmiAgent/Core/LLM/LLMProviderRuntime.swift:136` | trim 后设置 `Authorization: Bearer <key>`；请求 Content-Type 为 application/json |
| 正文 | `PalmiAgent/Core/LLM/LLMProviderRuntime.swift:153` | 使用 runtime model 的原始 id；DeepSeek 域名发送 thinking 方言，检查阶段为 disabled |
| HTTP 错误 | `PalmiAgent/Integrations/Intelligence/LLMAPIClient.swift:1688`、`:2243` | 从真实 HTTP status 和返回 JSON 的 error message/code 生成提示；源码中未找到 governor 字面量 |
| URLSession | `PalmiAgent/Integrations/Intelligence/LLMAPIClient.swift:2526` | 普通 URLSessionConfiguration.default，未配置专用代理、拦截器或重定向 delegate |

获取列表成功只证明该 GET 得到了可解析的成功响应，不能当作 Chat 认证成功证明。源码没有在列表成功后用模型做认证探测；也未核实官方 `/models` 在当前服务状态下是否要求有效 Key，因此不能反推 Key 必然有效或必然无效。

## 可由正常 UI 排除的端点差异

本地 DeepSeek 预设明确给出无 `/v1` 的 Chat 地址，但 `createChatCompletion`（`LLMAPIClient.swift:840`）实际根据 `configuration.baseURL` 重新推导。根地址经过 `OpenAICompatibleEndpointResolver`（`LLMModelDiscoveryService.swift:126`）默认产生 `/v1/chat/completions`。因此源代码存在“预设端点与实际推导端点不同”的可确认事实。

这**不能直接解释 401**：DeepSeek 官方 WorkBuddy/CodeBuddy 指南明确使用 `https://api.deepseek.com/v1/chat/completions` 和 `deepseek-flash`，表明加 `/v1` 本身属于官方使用方式。[官方 WorkBuddy/CodeBuddy 指南](https://api-docs.deepseek.com/quick_start/agent_integrations/workbuddy/)

若主代理需要排除该差异，可在同一连接的正常编辑 UI 把地址设置为 `https://api.deepseek.com/chat/completions`，协议保持 Chat Completions，模型保持 `deepseek-flash`，Key 保持不变，然后只做一次文本检查。完整路径由解析器识别为显式端点，避免自动补 `/v1`。此测试未由本诊断执行。若同样 401，则记录失败并避免把地址差异继续当根因。

## 尚未验证的事项

- 设备实际出站请求是否与本地当前源码构造一致（设备 build 与工作区版本尚未逐文件核验）。
- 服务端究竟拒绝了缺失、无效、已撤销、账户不匹配或其他状态的 Key；用户提供值一致不等价于服务端认定有效。
- 是否存在系统或外部网络路径改变请求；本诊断没有访问系统代理、安全配置或设备抓包。
- `governor` 的具体服务端含义；目前无官方依据，不能据字面断言。
- 另一官方服务此前也失败仅为现场关联线索，不能用它单独证明共享网络故障。

下一步应只记录一次 UI 端点对照结果；若认证仍被拒绝，需凭服务端账户/Key 状态证据再定位，当前不能宣称已找到或已修复根因。
