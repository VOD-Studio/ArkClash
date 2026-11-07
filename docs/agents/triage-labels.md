# 分诊标签

skill 用两个类别角色和五个状态角色描述 issue。本仓库的标签名和角色名完全一致：`to-spec`、`to-tickets` 会直接写 `ready-for-agent`，名字一致就不会建出重复标签。

| 角色 | 标签 | 含义 |
|---|---|---|
| 类别 | `bug` | 坏了 |
| 类别 | `enhancement` | 新功能或改进，文档也归这类 |
| 状态 | `needs-triage` | 待维护者评估 |
| 状态 | `needs-info` | 等提问人补充信息 |
| 状态 | `ready-for-agent` | 规格完整，agent 可以独立完成 |
| 状态 | `ready-for-human` | 需要人来做：华为账号、签名、产品取舍 |
| 状态 | `wontfix` | 不处理；重复或无效的 issue 也用它关闭，评论里写明原因 |

每个分诊过的 issue 恰好带一个类别、一个状态。issue 模板会自动加上类别和 `needs-triage`。

## 附加标签

- `needs-device`：完成标准包含真机验证（动到内核、NAPI、VPN，见 AGENTS.md「构建与真机验证」）。可以和 `ready-for-agent` 同时出现：agent 只在手机连着时领取。
- `wayfinder:map`、`wayfinder:research` / `prototype` / `grilling` / `task`：`/wayfinder` 专用，地图和决策票只带这些标签。
- `autorelease: pending` / `autorelease: tagged`：release-please 自动管理，不手动加。
