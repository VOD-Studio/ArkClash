# 0015 设置以事务快照保存，生效路径在 Go 显式声明

- 状态：目标决策，待实施（2026-11-13）
- 存储合同：[0017](0017-revisioned-file-store.md)。

## 背景

FlClash通过隐式区分update和setup输入，选择600ms就地更新、2–10秒防抖重建或提示VPN重启。后续实现者容易误把未勾选的覆写写成默认值、取消键后不恢复订阅值，或把通知和按需字段当成只影响界面。

ArkClash目前设置散在preferences和runtime.json，不能作为完整配置功能的多进程真源。

## 决定

Settings逻辑对象带schemaVersion，分app、theme、proxiesStyle、core、network、vpn、dav、excludeSSIDs。字段含义/默认值按手机领域规格；设备权限历史不混进可恢复备份。

设置通过共享Store事务保存，带expectedRevision，UI编辑可防抖600ms，离开/立即应用前必须flush。Go和宿主读取同一revision。若需要settings.json给启动代码读取，它只能是可重建的只读派生快照，不能成为第二真源。

`internal/settings/effects.go` 一处声明字段的生效路径，允许同一字段多个effect：

| effect | 行为 |
|---|---|
| live | 在当前配置上更新；未启动时只记目标参数，不能因此打开入站 |
| rebuild | clamp(上次构建应用耗时,2s,10s)后重建；去掉覆写键也走这里 |
| reconnect | 与已建TUN的有效参数比较，提示点击重启，不自动断流 |
| host | 更新通知动作、SSID排除、自动更新等宿主行为 |
| telemetry | 更新日志捕获、仅统计代理流量的采集和口径 |
| ui | 仅主题、材质、代理页样式等本地展示 |

`settings.apply(revision)` 返回实际已应用revision、待重建任务、待重连与失败项。持久化成功不等于已生效；界面必须显示pending/failed并可重试。新增字段同时修改ArkTS类型、Go结构、生效表和默认值夹具。

覆写是键集合与值，不在集合里的沿用订阅；新增/移除键的默认重置、DNS空值例外、testUrl不写YAML等按锁定源码实现。

有效VPN选项由Go计算（CIDR差集、私网绕过、IPv4/IPv6、地址/DNS/MTU/名单），宿主只翻译真实VpnConfig字段。空包含配置采用默认路由再应用排除；最终没有任何接管路由时返回NO_ROUTES，允许保存草稿但拒绝启用/重连并保留旧会话，不能回退成全路由。该拒绝行为是目标设计的显式差异，需平台门禁验证。栈、MTU、名单能力和权限受平台门禁约束，不能造不存在的系统字段。

## 后果

- 设置的持久化、运行态和VPN当前快照可分别解释，避免按钮值改变就谎报生效。
- 授权前可编辑保存，宿主上线后读取最新完整快照；需要核心校验的草稿明确标记待校验。
- 迁移0.4.x先备份旧数据，提交新manifest并读回成功后才标记完成，不能先删除唯一旧副本。
