# 0020 VPN 网络设置在建立隧道时应用

- 状态：已采纳，待真机验收

## 背景

工具中的网络设置需要同时控制系统 VPN 和 mihomo 的 TUN。HarmonyOS 在 `VpnConnection.create` 时读取地址、DNS、路由和 MTU，运行中的 VPN 无法热改这些参数。内核仍由 VPN 进程持有，配置热切换仍复用当前 TUN。

## 决定

- UI 将用户选择保存到独立的 Preferences。连接前把设置快照与 VPN 意图、操作 token 一起写进 `runtime.json`，扩展以同一快照创建系统 VPN 和内核 TUN。已连接时修改的设置在下次连接生效。
- 路由地址为空时使用已启用地址族的默认路由。系统 VPN 接受包含路由列表，因此扩展先从包含项中扣除排除项和选中的私有网段，并保证 VPN DNS 的主机路由可达。开关「DNS 劫持」只控制进入 TUN 的通用 TCP/UDP 53 端口劫持，系统配置的 VPN DNS 仍由 mihomo 处理。
- 默认保持 gVisor、MTU 1500、IPv4 全量路由和 DNS 劫持。IPv6 在系统和内核两端同时启用，最小 MTU 为 1280。系统仍将本应用排除在 VPN 外，出站 socket 仍绑定物理网络。
- HarmonyOS API 26 的 `VpnConfig` 提供互斥的 `blockedApplications` 与 `trustedApplications`（API 23 起上限均为 256）。应用访问控制支持关闭（`off`）、绕过所选（`blocked`）与仅代理所选（`trusted`）三种模式，黑/白两份名单独立保存、切换模式不互相清空。关闭和黑名单模式下向 `blockedApplications` 合并 ArkClash 自身包名（黑名单用户上限 255）；白名单模式仅下发 `trustedApplications`（剔除自身、用户上限 256）且拒绝空名单，避免空数组被系统按全量代理处理。公开 SDK 不支持普通三方应用读取已安装应用列表或查询他包信息，界面采用独立「应用访问控制」页提供内置常用鸿蒙应用目录与免权限 `PasteButton` 剪贴板 / `hdc shell bm dump -a` 批量导入，不向 `module.json5` 写入 `querySchemes`。公开 SDK 未提供 VPN 专属 HTTP 代理、HTTP 代理排除域名或 Android `allowBypass()` 对应的通用开关，系统代理和其排除域名在网络页显示平台不可用。[HarmonyOS VpnConfig](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-net-vpnextension/)

## 后果

网络页和访问控制页共享 `client/VpnNetworkSettings` 内存缓存，打开和连接时各异步读一次设置，没有常驻任务；备份恢复后清理共享缓存。路由计算只发生在保存校验和连接时。修改当前生效的访问控制模式或对应名单时提示重连，修改未启用的另一份名单不触发无意义重连提示。

真机验收用同一设备、同一订阅和同一上游网络，验证四种协议栈连接、IPv4/IPv6 DNS 与 TCP/UDP、私有路由绕过、排除网段和重复连接。用两个应用分别验证黑名单绕过与白名单仅代理（确认白名单下仅所选应用命中代理节点、另一应用直连且不入连接记录，同时验证本应用订阅更新、测速与出口探测无回环），并补充记录全未安装包名白名单及应用分身在真机上的实际分流表现。另录制冷启动到可操作的时间，记录 8 小时待机耗电、新连接建立时间与 24 小时内核重启次数。当前宿主环境没有 HDC 设备，尚无真机测量值。
