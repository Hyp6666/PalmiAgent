# App Store 素材规格与叙事调研

核验日期：2026-10-30（Asia/Shanghai）。仅浏览公开 Apple 文档及美区公开产品页；未访问用户 App Store Connect、未上传素材、未操作模拟器。以下为当前公开规则及设计建议，不代表用户账号内的实际槽位已核验。

## 可执行交付规格

采用不透明 PNG，RGB/sRGB 导出；同一语言同一设备尺寸交付 9 张，文件名前缀 01–09。Apple 接受 JPEG/JPG/PNG，禁止 alpha/透明，每个设备尺寸 1–10 张。推荐 RGB/sRGB 是制作选择，不在此声称 Apple 只允许该色彩配置。

| 用途 / 当前 Apple 名称 | 竖版像素 | 本轮建议 |
| --- | --- | --- |
| iPhone with Dynamic Island (medium display) | 1179×2556 或 1206×2622 | **主交付 1206×2622**；当前正文 Required device sizes 指定此类 |
| iPhone with Dynamic Island (large display) | 1260×2736、1290×2796、1320×2868 | 额外交付 1320×2868，延续大屏覆盖；旧称常见“6.9英寸” |
| iPhone with Face ID (large display) | 1284×2778 或 1242×2688 | 当前表格仍有“未提供 Dynamic Island 大屏则需提供”的条件说明；旧称常见“6.5英寸” |
| iPhone Duo 外屏 | 1398×2034 | 作为独立 Duo 素材，不代替常规 iPhone |
| iPhone Duo 内屏 | 2007×2853 | 作为独立 Duo 素材，保留展开布局 |
| iPad 13英寸（应用支持 iPadOS 时） | 2064×2752 或 2048×2732 | 使用真实 iPad 布局；横版可用 2752×2064 或 2732×2048 |

以上横版均为宽高互换。规格来源为 [Apple Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)，核验于 2026-10-30。注意：搜索结果摘要仍可能保留旧的“6.9/6.5英寸必需”措辞；直接打开正文已改为 medium 必需。为避免文档转换期歧义，本轮同时保留 medium 和 large 两套常规 iPhone 输出，而不只依赖历史 1284×2778 资产。

Apple 允许界面一致时自动缩放覆盖较小尺寸；有特定布局或语言需求时可独立提供。该能力不能把折叠展开的宽界面自动变成常规手机布局。截图和预览的排序、设备尺寸、语言 placement 可在 Media Manager 分别管理。[Apple Manage your App Store assets](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets)，核验于 2026-10-30。

## iPhone Duo 与 Device Hub 的区别

截至核验日，Apple 官方规格正文**确实列有 iPhone Duo**，并注明：2027 年 4 月起，使用 iOS 27.1 SDK 或更高版本的应用需提供该设备截图；提交 Duo 截图后产品页可显示优化徽章。本结论只依据当前官方页面，不依据传闻或 Device Hub 自定义名称。[Apple Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)。

Device Hub 中显示的设备名、用户自定义名字、窗口尺寸与 Apple 商店槽位是不同概念。采集记录应分别保存“Device Hub 显示名 / 实际像素 / 内外屏状态 / UI语言 / 预期ASC类别”。官方页面有 Duo 类别不代表任意名为 Duo 的本地设备截图天然符合像素与布局要求。

常规 iPhone 交付策略（设计判断）：

1. 优先用常规 iPhone 窄屏的真实 UI 采集，放入 1206×2622 和 1320×2868 宣传画布。
2. Duo 内屏用于独立展开体验资产。常规 iPhone 宣传图如需展示其优势，可把完整宽屏捕获等比放在留白中，明确其展开场景；不要拉长 UI、裁掉一半后伪装成窄屏原生界面。
3. Duo 外屏也不等同常规 iPhone 长宽比；等比嵌入可作版式素材，但若内容需表现常规手机使用体验，应重新采集窄屏布局。
4. 不用设备外壳或“已优化”标题代替真实适配证据。Apple 2.3.3 要求截图展示应用实际使用，允许文字/图像叠加；2.3.9 要求使用虚构账号数据。[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata)。

## 语言、地区与数量

9 张是每种语言、每种尺寸的一套：例如 en-US/medium 9 张与 zh-Hans/medium 9 张互不占对方的 10 张上限。商店元数据本地化与 Xcode 二进制语言设置不同；用户看到哪种语言还受商店支持及语言匹配/回退影响，不是简单的“一地区一套图”。新建语言时截图默认继承主语言，因此双语交付须检查截图内 UI 和画外标题，而不能只翻译画外标题。[Apple Localize app information](https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information)，核验于 2026-10-30。

## 推广文本、描述与此版本新增

| 字段 | 作用与限制 | 本轮写法 |
| --- | --- | --- |
| 推广文本 Promotional Text | 最多170字符；描述上方；可不发新版更新 | 一句话点出当下最强收益和一项亮点，避免罗列更新流水账 |
| 描述 Description | 最多4000字符；必填，可本地化；纯文本、支持换行、不支持HTML；产品页展示；通常随新版更新 | 首句解释产品价值，再列长期能力、使用条件及必要说明 |
| 此版本新增 What’s New | 最多4000字符；首版无此字段，后续版本必填，可本地化；产品页及更新入口展示 | 只写这次真正新增、改善与修复，不复述整份产品介绍 |

限制依据 [Apple Platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/)，展示和编辑说明依据 [Apple Creating your product page](https://developer.apple.com/app-store/product-page/)，均于 2026-10-30 核验。前者页面未提供固定发布日期；核验日不是规则发布日期。

截图承担长期购买理解：先让新用户知道“能替我完成什么”。版本改动留给 What’s New；推广文本可强调本期亮点。Apple 建议无预览时优先重视搜索中出现的前 1–3 张，后续每张聚焦一个主要收益；深色模式适合有证据时展示一张。[Apple Creating your product page](https://developer.apple.com/app-store/product-page/)。

## 当前优秀案例：实际浏览与可借鉴点

以下于 2026-10-30 实际查看美区公开产品页可见的首屏截图区域；不据此声称其转化率领先，也不推断不可见的后续图。

| 案例 | 当前可见设计 | 对 Palmi 的启发 |
| --- | --- | --- |
| [ChatGPT](https://apps.apple.com/us/app/chatgpt/id6448311069) | 白底统一卡片，短动词标题，如 Create new worlds / Talk it out anytime / Get quick answers；大幅真实 UI，单卡单场景 | 标题讲结果，UI 讲证据；每张保持统一边距和手机比例 |
| [Claude](https://apps.apple.com/us/app/claude-by-anthropic/id6473753684) | 暗色生活摄影与简短衬线标题结合；可见 Get useful answers wherever you are、Plug in your everyday tools；UI/工具图标作为场景证明 | 用使用情境和收益组织信息；品牌气质连续。其摄影风格不宜机械复制到Palmi |
| [Things 3](https://apps.apple.com/us/app/things-3/id904237743) | 蓝紫色背景与大手机界面；Meet Things、Focus on what matters today、Plan ahead；示例中有真实任务内容与清晰层级 | 用具体例子代替空状态；先总价值再今日任务、计划等工作流 |

三者可见共性（观察总结）：前段建立产品价值；一张一个主要信息；大 UI 让用户辨认；文案围绕可完成的事；统一视觉系统允许局部变化。它们并不共同使用同一种背景或设备外壳，Palmi 可保留自身蓝/象牙白气质。

## 9 张稳定卖点顺序框架

以下为供主制作代理结合当前可验证功能选择的框架，不是对 Palmi 未核验能力的承诺。序号 1–3 优先保证陌生用户一眼理解；第 9 张可删成8张。每张建议短主标题、一句补充、一个真实示例。

| 顺序 | 用户收益 / 候选标题方向 | 需要的实际画面证据 |
| --- | --- | --- |
| 01 | 从一个想法，到完成任务 | 一条完整Agent请求与结果，避免只有品牌和空输入框 |
| 02 | 把复杂问题，拆成清晰步骤 | 计划/执行中的可读步骤与最终成果 |
| 03 | 你的模型，在一个地方 | 当前确实支持的模型选择或配置；不展示密钥/个人账号 |
| 04 | 让图片与文件，加入对话 | 当前支持的多模态输入和有用的回复示例 |
| 05 | 看见每一步进展 | 实际执行时间线/工具记录，强调理解和掌握进程 |
| 06 | 让擅长的助手，各司其职 | 多Agent协作的真实可读状态及合并结果 |
| 07 | 把常用能力，变成工作方式 | Skills/工具的真实选择与调用；避免塞满术语 |
| 08 | 思考之后，也能创造 | 实际可运行的作品、游戏或其它可交付成果 |
| 09 | 每次对话，都有自己的空间 | 真实对话详情/角色或组织方式；若不够差异化，删掉此张 |

最后选图应以当前版本可复现的截图证据为准，把“已完成的成果”放在设置页之前。Duo展开画面属于版式适配维度，不单独挤占一个“新设备支持”卖点；长期价值优先。
