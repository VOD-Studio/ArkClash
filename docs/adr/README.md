# 架构决策记录（ADR）

记录"为什么这样做"。代码注释只写现在做什么、有什么坑，选择的理由和被否决的方案写在这里。

格式：编号递增，文件名 `NNNN-简述.md`，包含「状态 / 背景 / 决定 / 后果」。推翻一个决定时新写一份 ADR，并把旧的状态改成「已被 NNNN 取代」。

| 编号 | 标题 | 状态 |
|---|---|---|
| [0001](0001-core-in-vpn-extension.md) | 内核以 c-shared 库运行在 VPN 扩展进程 | 已采纳 |
| [0002](0002-patched-go-toolchain.md) | 用打补丁的 Go 工具链编译内核 | 已采纳，由 0014 扩展 x86_64 |
| [0003](0003-ui-core-via-external-controller.md) | UI 通过 external-controller 和文件通道与内核通信 | 已采纳，由 0009 扩展 |
| [0004](0004-exclude-self-by-uid.md) | 按 UID 把本应用排除在 VPN 之外 | 已被 0008 取代 |
| [0005](0005-gvisor-default-stack.md) | TUN 默认使用 gVisor 协议栈 | 已采纳，待真机数据复核 |
| [0006](0006-layered-ci.md) | 分层 CI，单一必需检查，发版只构建一次 | 已采纳 |
| [0007](0007-min-harmonyos-7.md) | 最低支持 HarmonyOS 7（API 26），界面以 UI Design Kit 为准 | 已采纳 |
| [0008](0008-bind-core-sockets-to-physical-network.md) | Go 出站逐 socket 绑定当前物理网络 | 已采纳 |
| [0009](0009-arkclash-commands-on-controller.md) | ArkClash 自有命令挂在 controller 上 | 已采纳 |
| [0010](0010-hot-switch-reload-in-vpn.md) | 热切换由 VPN 进程重载配置 | 已采纳，目标与节点恢复由 0012 补充 |
| [0012](0012-profile-state-and-runtime-separation.md) | 配置持久状态与实际运行状态分离 | 已采纳，待统一真机验收 |
| [0013](0013-runtime-host-process-evidence.md) | 用系统进程事实恢复异常终止的运行宿主 | 已采纳，宿主回归与 API 26 真机启停、转发通过 |
| [0014](0014-x86-emulator-toolchain.md) | 为 x86_64 模拟器单独适配 Go 工具链 | 原生加载、双 ABI 构建与签名应用启动通过，VPN 转发待验收 |
| [0015](0015-geo-resource-management.md) | Geo 设置、任务与数据库按进程明确所有权 | 已采纳，设备和性能门禁独立验收 |
| [0016](0016-visible-diagnostics.md) | 连接与 DNS 记录只在对应工具页可见时采集 | 已被 0019 取代 |
| [0017](0017-core-ready-without-vpn.md) | 一个核心预热，系统 VPN 转发独立启停 | 已采纳，宿主与 Linux fd 回归通过，手机驻留和性能待验收 |
| [0018](0018-ui-appearance.md) | 应用外观只由 UI 进程管理 | 已采纳 |
| [0019](0019-app-diagnostics-capture.md) | 诊断采集跟随应用，实时列表跟随页面 | 已采纳，设备性能独立验收 |
| [0020](0020-vpn-network-settings.md) | VPN 网络设置在建立隧道时应用 | 已采纳，待真机验收 |
| [0021](0021-global-dns-overrides.md) | 全局 DNS 逐项覆写 | 已采纳，待真机验收 |
| [0022](0022-added-rules.md) | 全局附加规则优先于配置规则 | 由 0028 扩展 |
| [0023](0023-profile-scripts-in-vpn.md) | 配置覆写脚本在 VPN 进程执行 | 已采纳，覆写顺序由 0030 更新 |
| [0024](0024-local-proxy-library.md) | 自定义代理库与内核校验 | 已采纳，待真机验收 |
| [0025](0025-managed-rule-sets.md) | 规则集库与附加规则引用 | 已采纳，待真机验收 |
| [0026](0026-proxy-filter-presets.md) | 筛选预设与配置 YAML | 已采纳，待真机验收 |
| [0027](0027-icon-set-library.md) | 图标集库与代理组图标 | 已采纳，待真机验收 |
| [0028](0028-standard-profile-overrides.md) | 标准覆写的规则顺序与应用时机 | 已采纳，覆写顺序由 0030 更新 |
| [0029](0029-general-settings-and-log-capture.md) | 常规设置、外部控制器与日志采集 | 已采纳，待真机验收 |
| [0030](0030-composed-overrides-and-live-status.md) | 脚本与附加规则组合、仪表盘运行状态 | 已采纳，待真机验收 |
| [0031](0031-portable-backup.md) | 原子恢复配置库与 WebDAV 备份 | 已采纳 |
| [0032](0032-structured-custom-profile.md) | 自定义配置的结构化编辑 | 已采纳 |
| [0033](0033-age-subscriptions.md) | 订阅下载中的 age 解密 | 已采纳 |
| [0034](0034-harmonyos-system-dns.md) | 从鸿蒙默认网络读取系统 DNS | 已采纳，待真机验证 |
| [0035](0035-tailscale-network-monitor.md) | Tailscale 出站使用鸿蒙默认网络 | 已采纳 |
| [0036](0036-vpn-memory-pressure.md) | 在 VPN 进程响应系统内存压力 | 已采纳 |
