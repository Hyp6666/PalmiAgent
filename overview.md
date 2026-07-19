# 后台偶发断联分析概览

- 完成了 Scene #17 的只读代码分析，未修改源码。
- 核心判断：当前 iOS 后台能力是系统可到期的 continued processing，不是永久常驻；到期回调会明确取消 Agent run。
- 同时发现普通 background task 仅用于立即落盘、后台保护注册/提交失败缺少用户可见状态、恢复前台或网络后没有自动续跑状态机。
- 详细证据、验证步骤与最小修复方向见 `artifacts/scene-17-background-disconnect-analysis.md`。
