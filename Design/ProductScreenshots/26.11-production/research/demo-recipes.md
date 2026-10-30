# Palmi 真实截图演示配方

代码核对日期：2026-10-30。仅阅读 app 代码；未运行模拟器、未读取密钥、未修改 app 源码。以下是待在 app 中真实发送和操作的配方，不能视作已执行结果。文件由 app 工具生成，不从宿主后门写入 app 容器。

## 最省请求的安排

聊天 1 次生成 2048；专业 1 次准备成果、浏览器、项目文件、来源和 Python 过程；模型选择、技能库仅打开现有 UI；仿生使用内置 Palmi，发 1–2 条短消息。中英分别运行对应版本，避免只改界面语言却保留另一语言的内容。

| 图 | 实际界面与动作 | 是否另发请求 |
|---|---|---|
| 01 聊天 2048 | 聊天模式，发送下面 2048 请求；收键盘，真实滑动若干步再拍 | 1 次 |
| 02 专业成果 | 专业任务完成后的短结论、原生图表与三个文件链接 | 共用专业请求 |
| 03 浏览器 beta | 专业页扩展工具/侧栏→浏览器→已访问的 web.dev 标签 | 共用专业请求 |
| 04 项目文件 | 当前专业项目→文件；根目录显示 CSV/HTML/Markdown，或打开 report.md | 共用专业请求 |
| 05 模型选择 | 输入栏脑图标→推理面板→右侧模型名菜单；仅展示实际配置的模型 | 无 |
| 06 研究来源 | 最终回复真实来源链接与已核实事实，或推理过程→browser 详情的任务、步骤、输出 | 共用专业请求 |
| 07 端侧计算 | 顶部过程条→Python 步骤详情，展示真实输入和输出；备用为 scripts 中的 .py / logs 中的 .log | 共用专业请求 |
| 08 技能库 | 侧栏→技能，展示内置系统技能；当前项目技能页也可 | 无 |
| 09 仿生对话 | 专业页 Palmi 入口→内置 Palmi→短对话 | 1–2 次 |

## 01：聊天内 2048

中文首选：

> 做一个能在这条回复里直接玩的经典2048。原生系统配色，透明背景，棋盘最大宽340，手机单屏能看全。支持滑动合并、分数、重开，保存局面；开局按经典规则，别加长说明。

English:

> Make a classic 2048 I can play right inside this reply. Use Palmi's system colors and a transparent background, with a square board no wider than 340px that fits a phone screen. Include swipe controls, score, restart and saved game state. Start with a normal new game. Keep the introduction to one short sentence.

若模型只提供源码或文件，最短修正：

> 请直接输出一个完整的 palmi-ui 交互块，kind 为 html；不要创建文件或显示源码。棋盘使用 touch-action:none，沿用 --palmi-* 颜色变量。

> Return one complete palmi-ui block with kind "html", directly in the answer. Do not create a file or show source code. Use touch-action:none on the board and the --palmi-* color variables.

实际拍摄：等围栏完整结束、棋盘出现、加载指示消失；收键盘；在棋盘内真实滑动约12–20次，使画面有真实局面。可用固定方向循环：左、下、左、上、右、下，每次确认局面变更。不要假设手势已成功，也不要注入脚本改分数。若在同方向无合法移动，换方向。

呈现契约：

- 执行入口是助手公开回复里的独立 `palmi-ui` 围栏，内部为完整 JSON；`version:1`、唯一 `id`、`kind:"html"`、`title`、`summary`、`html` 必需。普通 `html` 围栏不可执行，工具输出与工作区 HTML 文件也不可替代它。
- 2048 应选 HTML，因为需要自定义棋盘和手势。“原生配色”指采用宿主颜色，不是 `kind:"native"` 的组件拼棋盘。
- HTML 应离线自包含，禁用网络/外部库/浏览器存储。`window.PalmiUI.getState()` 同步恢复，`setState()` 每次传完整标量字典；数组不能直接放 state，棋盘可编码为短字符串。
- 棋盘 `touch-action:none`，周边仍允许聊天滚动。不要 `100vh` 或整页背景。设计按320pt宽可用，棋盘正方形、状态一行、一个重开按钮，整体约400–470px高。
- 内联 HTML 宿主高度上限720pt；自动按内容测高，不是固定全屏。无需展开成另一页面。

## 02/03/04/06/07：同一专业请求

先用真实 UI 新建/选择项目。建议名：中文“网站体验复盘”；英文“Website Experience”。文件放当前项目根目录，保证文件页有三个直接可见交付物。

中文：

> 用这组演示数据做网站LCP六周复盘：W1–W6分别为3.8、3.4、3.1、2.7、2.4、2.2秒。用browser打开 https://web.dev/articles/lcp 核实良好阈值并保留标签；用一次Python标准库计算首末改善比例及达标周数，保存脚本 scripts/analyze.py。用文件工具在当前项目根目录创建 metrics.csv、chart.html（离线SVG柱状图，含阈值线）、report.md（结论及真实来源链接），每个都简短。明确数据为演示。最终回复只要两句结论、一个紧凑的原生配色柱状图和三个文件链接，不贴源码。

English:

> Review this demo site's weekly LCP: W1–W6 are 3.8, 3.4, 3.1, 2.7, 2.4 and 2.2 seconds. Use browser to open https://web.dev/articles/lcp, verify the good threshold and keep the tab. Use one standard-library Python run to calculate the first-to-last improvement and number of weeks meeting the threshold; save scripts/analyze.py. Use file tools to create metrics.csv, chart.html (offline SVG bars and a threshold line), and report.md (findings and a real source link) in this project's root. Keep all three small and label the data as demo. Finish with two sentences, a compact native bar chart using system colors, and three file links. Do not show source code.

预期真实工具：一次 `browser(task:...)` → 一次 `python(script:..., save_to:"scripts/analyze.py")` → 三次 `edit(operation:"write",...)`。模型可能先看目录或读现有文件，这是正常真实过程，不必强迫指定工具序列。`browser` 是自主子执行器，一次调用内部可有多个页面步骤；“一次 browser”不能保证仅一次底层网页读取。

预期核对：若页面确认良好阈值为≤2.5秒，则改善 `(3.8-2.2)/3.8 = 42.1%`；W5/W6达标，为2/6周；末周2.2秒。这里只分析给定演示的周级LCP值，不应宣称已测量真实网站或拿到用户的性能数据。

最终原生图表用于02聊天成果图；独立 chart.html 用于04文件交付证明。这是两种不同对象。项目文件预览把 `.html` 视为纯文本，点击它将看到源码，不能以它充当已渲染的图表。要拍可读文件成果，打开 report.md；要拍可交付格式，停留根目录。

若最终只给文件而缺图，轻量追加：

> 把刚才六周数据在回复里用一个原生palmi-ui柱状图展示，标题“LCP持续改善”，单位秒，其他不用重复。

> Show those six weeks in one native palmi-ui bar chart titled “LCP keeps improving”, in seconds. Do not repeat the report.

若来源没清楚露出，用当前会话追问，不增加联网：

> 只列出刚才实际打开的来源链接、核实到的LCP阈值，以及它支持的一个结论；不要重新联网。

> List only the source you actually opened, the LCP threshold you verified, and one conclusion it supports. Do not browse again.

06的边界：当前可确认的真实来源证据是 browser 返回报告、其步骤详情以及最终实际链接。旧 `AgentEvidencePanel` 有“参考资料/来源”结构，但代码中未找到 `SourceDigestArtifact(...)` / `SearchSelectionArtifact(...)` 的生产构造调用，不能保证一次 browser 后旧抽屉有来源条目，也不能往存储里填条目伪造。最稳妥按表中现有页面拍。

07的边界：是真正随 app 嵌入的 CPython 3.14 执行。不要写“模拟终端”，也不用编造Linux shell。标准库即可；numpy/pandas/matplotlib/requests不在包列表。Python内联执行自动保存脚本，并生成 logs 下真实输出记录；详细工具输出中可见运行信息。仅成功后拍“已完成”。

## 05：模型菜单，无需生成内容

当前界面入口是输入栏上方脑图标，展开约310pt宽推理面板；面板底行**右侧模型名**是菜单按钮，其余行文字不是。菜单按真实连接来源分组，可能是二级菜单。选择适合截图的真实已配模型来源展开即可，无需切模型或发新请求。不要在截图中填假模型/账号。

## 08：技能库，无需安装

代码内置且始终启用的系统技能只有两个：`skill-creator`、`bionic-persona-creator`。全局与当前项目页都列系统分区；没有导入包时导入/项目空分区不会显示。可直接截图真实内置库，或打开一个技能详情。不要为了填满列表而在后台制造已导入状态。

若确实需要展示“用户技能”能力，另开真实专业请求创建并 `import_skill`；这会多读 skill-creator、多写包、多安装，非九图最省token方案。

## 09：内置 Palmi 仿生对话

从专业页的 **Palmi** 入口进入；该动作调用 ensureSystemRole，自动准备应用提供的头像/角色并切到仿生会话。不要用右上“创建角色”或 `create_bionic_persona`，也不需要创建同名角色。系统角色默认即时回复、主动联系关闭。若已有角色内容，使用现有真实会话，不删档重建。

中文首条：

> Palmi，今天终于把拖了很久的小项目做完了。想先歇一会儿，你会怎么陪我庆祝？简短聊两句就好。

English:

> Palmi, I finally finished the little project I'd been putting off. I'd like a quiet break. How would you celebrate with me? Just a couple of short lines.

需要补一来一回时：

> 那就一杯热茶和一首喜欢的歌吧。今天先不安排下一件事。

> A warm cup of tea and a favorite song sounds right. No planning the next task tonight.

不要求调用专业模式、不让角色联网或画图，避免变成工作流演示。等角色真正回复并收键盘，保留头像、自然气泡与短对话即可。中英版需在角色设置确认母语：内置Palmi允许改母语，普通角色母语不可如此更改；仅切app语言不必然改已有角色母语。

## 主要代码证据

- `PalmiAgent/Core/GenerativeUI/PalmiGenerativeUIPrompt.swift`：完整 palmi-ui 输出、native/html路由、手机适配、宿主颜色和状态约束。
- `PalmiAgent/Core/GenerativeUI/PalmiRichContentParser.swift`：仅处理精确 `palmi-ui` 围栏，关闭后解码；普通HTML围栏不会执行。
- `PalmiAgent/SharedUI/GenerativeUI/PalmiHTMLArtifactView.swift:35`：内联高度夹在60…720，展开最高1200；WebView不自行滚动。
- `PalmiAgent/SharedUI/WorkspaceFilePreview.swift:30`：HTML/CSV/Python/log都是text预览；Markdown单独渲染。
- `PalmiAgent/Integrations/Intelligence/LLMToolDefinitionBuilder.swift:69`：Python能力；约95行browser整任务委派；约149行edit写文件；约359行Python参数。
- `PalmiAgent/Core/Sandbox/PythonNotebookSandboxService.swift:33`：内联脚本持久化；约45行执行与日志。
- `PalmiAgent/Core/Sandbox/EmbeddedPythonRuntime.swift:6`：实际内置包列表、不支持包；约68行CPython运行说明。
- `PalmiAgent/Features/Chat/NeoRuntimeViews.swift:48`：过程卡入口；约150行步骤详情；约310行真实工具输入/输出详情。
- `PalmiAgent/Features/Chat/ChatScreen.swift:487`：脑图标与推理popover；约563行右侧模型菜单。
- `PalmiAgent/Features/Workspace/PalmiDrawer.swift:112`：浏览器/文件/技能入口。
- `PalmiAgent/Features/Workspace/SkillManagementScreens.swift:113` 与 `PalmiAgent/Resources/Skills/`：系统技能分区与两个内置包。
- `PalmiAgent/Features/Workspace/WorkspaceShellScreen.swift:385`：专业Palmi入口，确保系统角色后才切仿生。
- `PalmiAgent/Core/Bionic/BionicSystemPersona.swift`：内置头像、Palmi名、即时回复、主动关闭、允许更改母语。
- `PalmiAgent/Resources/Skills/bionic-persona-creator/SKILL.md:10`：内置Palmi已提供，不为跳转聊天另建同名角色。
