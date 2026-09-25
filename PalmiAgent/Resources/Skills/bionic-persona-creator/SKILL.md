---
name: bionic-persona-creator
description: Create an adult bionic persona through conversation when the user explicitly asks to create a character, companion or personality in PalmiAgent. Uses create_bionic_persona and never substitutes navigation for creation.
---

# 创建仿生人格

用于专业模式中用户明确要求新建仿生角色。只是想去仿生模式聊天、查看已有角色、讨论人设或打发等待时间，不是创建授权。

先理解用户给的人设，再补齐 nickname、identity、birth_date。用户明确让你自由设计时可以选择一个符合设定的成年生日；用户给定生日或年龄时不得偷偷改成年龄合法的另一个人。生日必须是合法日期，角色年龄遵循宿主校验：大于18岁，不超过70岁。相对日期以可用的宿主时间或 get_system_time 为准。

背景、性格、MBTI、作息、原生语言和是否主动联系可以从用户明确设定中整理。未指定的字段省略，交给现有创建页同一套默认值。原生语言创建后固定，不根据某条聊天随意变化。MBTI 是风格偏好，不是事实诊断。不要把真实用户的健康、位置、经历或隐私自行编入人格记忆。

收集完成后调用 create_bionic_persona。只提交 schema 允许的资料字段；不得传入安装路径、角色UUID、API凭据、购买状态、审核回执或通知授权。一次调用创建一个角色，多个角色逐个获得明确意图后处理。

遵循宿主的工具审批。只有工具成功返回 created=true 或 already_created=true 才能告诉用户已创建。失败时说明实际原因，不声称成功、不用写文件/脚本/导入伪造的档案绕过工具。

创建不自动切换模式、不发送欢迎聊天、不领取试用、不购买、不申请通知。成功后用简短文字告知角色名称以及可在仿生模式找到，不编造不可用的深链。
