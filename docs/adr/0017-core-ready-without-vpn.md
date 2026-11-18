# 0017 内核就绪与系统 VPN 转发分离

- 状态：已采纳；宿主行为与 race 回归、Linux fd 所有权回归均已通过，ARM64 签名 HAP 已装机。真机已观察到未配置 TUN 地址时扩展和 controller 存活；界面、实际转发和性能验收尚未完成。

## 背景

节点选择和 mihomo URLTest 不需要系统 TUN。把核心启动和 VPN 创建绑在一起，会使未连接时无法测速，普通断开也会丢掉节点实例、测速状态和 fake-IP 映射。

API 26 的手机应用不能把 ArkTS/native 子进程、独立 UIAbility 或 AppServiceExtensionAbility 当作通用后台内核服务。继续使用唯一的 VPN 扩展宿主，UI 进程不加载 `libarkclash.so` 或 `libclash.so`。

`startVpnExtensionAbility()` 与 `VpnConnection.create()` 是两个步骤。首次授权由前者触发。因此自动预热会把系统授权提前到打开应用时；批准授权不等于已经接管系统流量。用户已选择这一流程，不采用第二个测速内核、UI 内核或 TCP ping 替代 URLTest。

## 决定

### 一个宿主、一个核心

首帧仍用缓存渲染。配置初始化、离线迁移和待写设置完成后，只在前台尝试预热：写入实例证据、安装 Geo、加载当前配置并启动 controller，但不创建系统 VPN、TUN 或业务入口。没有配置时使用默认空配置，不制造配置文件；已有配置解析失败仍报错。

| 场景 | 核心 | 转发与资源 |
|---|---|---|
| 预热完成 | `running=true` | `intent=stopped`、`forward=stopped`，`vpnCreated/tunAttached/listenersOpen=false` |
| 连接准备 | 保持同一实例 | `preparing`，依次创建系统 VPN、附加 TUN、恢复业务入口 |
| 已连接 | 保持同一配置与实例 | `running` 必须同时有真实 TUN 和系统 VPN |
| 普通断开 | 保留 controller、resolver、节点及 scheduler | 关闭业务入口和已接受的转发连接，卸载 TUN，再销毁系统 VPN |
| 清理失败 | 按实际资源保留事实 | `failed`，不伪造停止；宿主未知时禁止离线业务写入 |

连接与断开只增加普通 `revision`，不改变 `bootId`、`configRevision`、节点身份、选择和 fake-IP。`startedAt` 只记录本次成功连接的起点，预热和断开为 0。真正换配置才前进 `configRevision`、退休旧节点并取消旧配置测速。

`vpnCreated` 是平台资源事实：create 成功后置真，只有 destroy 成功或宿主死亡得到证明后才能清零。它不由 Go 的 `tunAttached` 推断。

### 业务入口与 fd 所有权

`core/lifecycle.go` 管核心启停、配置和 attach/detach；`core/lib.go` 只保留 C ABI。`core/inbound.go` 保存最小入口设置，不保留旧配置的代理/provider。detached 配置在应用前屏蔽端口、协议 server、自定义 listener、tunnel 和 DNS listen，不能先开放再关闭。controller 和 resolver/fake-IP 始终保留。

attach 新建自定义 listener，并恢复普通入口和 DNS 监听。detach 先停止接收本代转发任务，再取消未进入 tracker 的 TCP/UDP 拨号、关闭连接并等待任务退出；随后关闭入口和 TUN。在线热切换也先收尾本代转发，再应用新配置，不重建 TUN。独立 URLTest 不属于转发代次，普通断开不会取消它。实际端口及依赖中的加锁快照决定 `listenersOpen`，不按配置希望值推断。订阅不能创建另一份 TUN、自动路由或 iptables。

系统与 Go 分别持有 fd：平台保留 create 返回的原件；Linux `sing_tun.tunNew` 在真正接管接口的边界用 `F_DUPFD_CLOEXEC` 复制，Go 只关闭副本。构造回滚由 listener 负责，stack 在 Start 前登记到 listener，外层不得再盲目 close。Close 出错保留不确定性，重试不能再次关闭可能已被复用的描述符。

`scripts/mihomo-tun-fd.patch` 与现有补丁共用 `prepare-mihomo.sh`，不修改模块缓存。补丁还提供真实入口快照、可报告错误的关闭，以及同步的 DNS/controller 生命周期。完整关闭同时退休被 HTTP hijack 的 WebSocket，避免旧流越过下一次 boot。

`scripts/mihomo-inbound-lifecycle.patch` 让监听器从 Accept 起持有原始 TCP 连接，关闭时连未完成握手的连接一起释放；`scripts/mihomo-forward-lifecycle.patch` 隔离各代 TCP/UDP 转发，避免旧拨号或队列越过重载。

### 命令、意图和代次

唯一的 `vpn/Commands.ets` 注册 native 命令回调，统一路由 profile 与 VPN 命令。经原 controller secret 鉴权的 `/arkclash/vpn/connect`、`/disconnect` 复用命令转发与回复；HTTP 请求超时不取消已入队的操作。

UI 在原有配置存储短锁中原子写入 `vpnIntent` 和随机 `vpnOperation`，再发送命令。请求携带 `bootId/operationId`；连接还携带 profile/configRevision，Go attach 在同一锁内验证。断开不绑定配置修订。扩展在入队和异步返回后重读 secret/token/intent，迟到 connect 不能越过较新的断开。

create/attach/detach/destroy 共用一条队列。onDestroy 立即作废宿主代次，再等待启动和操作收尾；迟到 create 也必须清理。两类资源清理独立尝试，全部成功才写当前 secret+instance 的停止回执。普通断开不写宿主停止回执，也不停止扩展。

`CoreClient.startCore` 是 ensure-ready 单飞操作，只复用认证且实例一致的运行核心。只有已证明 stopped 才换 secret 并拉起扩展；unknown 沿用 [0013](0013-runtime-host-process-evidence.md) 的停止确认。授权由系统启动 Promise 返回，拒绝直接结束启动；成功后仍须等认证 controller 就绪。HBP-AL00 的 `libvpnextension.z.so` 在 GC 回收 `VpnObserver` 时发生过 UI 主线程 `SIGSEGV`，因此不再创建授权观察者。自动失败后本 UI 会话不再自动请求授权，用户可显式重试；不增加心跳或常驻轮询。

### 配置与界面

`coreReady/coreStarting` 与 VPN 状态分开。核心运行且前台时订阅运行事件；流量、出口和服务探测仍要求实际连接。连接与 DNS 诊断的采集和显示条件见 [ADR-0019](0019-app-diagnostics-capture.md)。

首个配置提交并释放存储锁后，若核心仍为空，加载最新 current。reload 的 `expectedProfile` 区分省略与空串：省略不约束，空串只允许激活空核心，防止迟到激活覆盖新选择。删除最后一个配置先断开并清空运行配置，再删除文件，保留空核心。节点页、分组和 picker 共用核心就绪条件；拒绝授权后仍可从现有空态或菜单显式启动核心。

## 后果与验收边界

普通断开不再释放核心，因此未连接驻留也会消耗内存和电量。手机固件是否允许无 TUN 扩展持续服务必须实测，不承诺无限后台常驻。系统回收后先取证再恢复；不在后台反复拉起扩展抢回 VPN。

宿主回归执行实际生命周期、入口控制和扩展逻辑；本地 HTTP/SOCKS 夹具验证真实 URLTest 经过未选中的节点且不改变出口。Linux 容器验证补丁的 fd 副本、回滚和复用安全；它不能替代手机 TUN 成功转发。

API 26 真机（HBP-AL00）上 `make run` 安装、启动成功。锁屏时观察到 ArkClash VPN 扩展进程存活、controller 在 `127.0.0.1:19090` 监听，`vpn-tun` 没有 ArkClash 的 `172.19.0.1` 地址。这只证明采样时的状态，不代表首次授权流程或长期驻留已验收。HDC shell 可读本应用线程数，不可读该进程的 `/proc/<pid>/fd`。

授权观察者修复后，同一真机在已有授权下开应用可预热且不创建 TUN；通过界面连断 4 轮，TUN 地址随操作出现和移除，UI 与 VPN 进程均未重启，断开后 controller 继续监听。浏览器访问 Google 的连接命中代理。未重置手机已有授权；系统 Promise 拒绝与显式重试由宿主回归覆盖。

仍须验证：首次授权后不接管流量、未连接单节点/分组/picker 测速、断开后配置身份保留、至少 20 次连断及本应用 fd/线程检查、首次添加与配置切换、网络切换、前后台和撤销授权。布局只解析 Button，临时布局立即删除，不导出订阅、secret 或节点信息。

| 指标 | 测量方法 | 本轮数字 |
|---|---|---|
| 冷启动到可操作，目标 <500ms | 同机同配置用启动跟踪，多次取中位数/p95，对比改动前与同类客户端 | 未测：未测到可操作首帧 |
| 未连接、已连接各 8 小时待机耗电 | 同网络、亮度、电量起点，拔电锁屏，用系统电量统计分别比较 | 未测：未开始对照实验 |
| 新连接建立延迟 | 同目标、网络与配置，用设备网络跟踪比较分布 | 未测：已验证转发，未采集延迟分布 |
| 24 小时稳定性 | 设备跟踪记录 bootId 与重启次数，不增加生产轮询 | 未测：未开展连续观测 |

## 来源

- [Stage 进程模型](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-models/process-model-stage.md)、[AppServiceExtensionAbility 限制](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/application-models/app-service-extension-ability.md)。
- API 26 本机 `@ohos.net.vpnExtension.d.ts` 与 `@ohos.app.ability.childProcessManager.d.ts`。
- [Nexus ConnectionOrchestrator](https://github.com/306026185/nexus-vpn-harmonyos/blob/main/Nexus_HarmonyOS/entry/src/main/ets/commons/services/ConnectionOrchestrator.ets) 与 [VpnExtensionAbility](https://github.com/306026185/nexus-vpn-harmonyos/blob/main/Nexus_HarmonyOS/entry/src/main/ets/vpnability/VpnExtensionAbility.ets)：只采信无 TUN 执行路径，不采信其“无需授权”注释，也不作为本机验证。
- OpenHarmony [VpnExecExt](https://github.com/openharmony/communication_netmanager_ext/blob/master/frameworks/js/napi/vpnext/src/vpn_exec_ext.cpp) 与 [NetworkVpnService](https://github.com/openharmony/communication_netmanager_ext/blob/master/services/vpnmanager/src/networkvpn_service.cpp)：destroy VPN 与 stop 扩展是独立路径。
