# 0010 热切换由 VPN 进程重载配置

- 状态：已采纳（2026-11-07）

## 背景

热切换（见 `GLOSSARY.md`）要求切换期间 VPN 不断开。mihomo 没有重载接口：`PUT /configs` 不经过 `applyOverrides`，配置里的 tun、controller 等字段会直接生效，而且 [0009](0009-arkclash-commands-on-controller.md) 已经把它关掉了。FlClash 的做法是在进程内调 `hub.ApplyConfig`。但这个函数里的 `applyRoute` 每次都会无条件关掉 controller 的 `http.Server` 再重开（`hub/route/server.go` 的 `start()`），触发重载的那个请求会被掐断，界面的 `/traffic`、`/connections`、`/logs` WebSocket 也会全部断开。

## 决定

- **重载流程**：读文件 → `config.UnmarshalRawConfig` → `applyOverrides` → `config.ParseRawConfig` → `executor.ApplyConfig(cfg, true)`。`applyRoute` 跳过不调：`applyOverrides` 每次都把 controller 的地址和 secret 设成同样的值，没必要重建 controller。冷启动仍用 `hub.ApplyConfig`。
- **成败标准**：只有解析这一步会失败。解析失败时内核保持原样，接口返回原因。解析通过以后的应用阶段（proxy-provider 下载失败、DNS 监听失败等）只写日志，算切换成功。
- **候选文件先过内核**：要替换正在运行的配置时，写入方先写一个候选文件，调重载让内核解析并切换，成功后再把候选文件改名提交；失败就删掉它。VPN 进程更新当前订阅（ArkTS 调 `core.reload`）和界面替换正在运行的本地配置（调 `POST /arkclash/reload`）都走这条流程，所以内核加载不了的配置永远不会替换掉正在用的那份。不在运行的配置只做 #35 定的轻量内容检查。重载只接受 `filesDir/profiles/` 下的文件。
- **界面发起的切换**：先调 `POST /arkclash/reload`，成功后界面再把列表文件里的当前配置改过来；失败什么都不写。
- **正在运行的配置由 VPN 进程记录**：VPN 进程在内存里记住正在运行的是哪份配置，状态接口能查到。自动更新完成后要不要热切换，拿它来比，不看列表文件，这样不会和界面发起的切换互相覆盖。`runtime.json` 去掉 `configPath`，VPN 进程启动时从列表文件读当前配置，系统直接拉起扩展进程时也能用上最新的选择。
- **出站模式和局域网代理归 ArkClash 接管**：界面把它们写进 `runtime.json`，`applyOverrides` 在启动和每次重载时强制使用；用户没选过的项，沿用配置里的值。不这样做的话，热切换时配置里的 `mode`、`allow-lan` 会悄悄覆盖用户的选择，而 VPN 进程自己发起的热切换没有界面在场，没人会补发。
- **VpnConfig 级设置不走热切换**：协议栈、IPv6、分应用代理，以后还有 VpnConfig 里的 DNS 地址和 MTU，改了只能断开重连。配置内容本身永远不会触发重连，因为 TUN 段已被 `applyOverrides` 强制关闭。

## 后果

- 热切换时 controller 和界面的 WebSocket 不会断，重载接口可以等切换完成再返回结果。界面靠 0009 的事件推送知道配置换了。
- 配置里的 `external-ui`、`cors`、`external-doh-server` 在热切换时不生效，这几项本来就被接管了，或者用不到。`log-level` 在热切换时改成 debug，也不会打开 `/debug`。
- 应用阶段 tunnel 处于挂起状态：新的 TCP 连接会被直接关闭，UDP 被丢弃，已经建立的连接继续走旧节点。provider 文件都在本地时，这个窗口在 20ms 以内（真机实测）；新配置里有还没下载过的 provider 时，要等下载完，真机上一份带 25 个 rule-provider 的订阅第一次切换等了 4 秒。为此 VPN 进程会在后台预先下载 rule-provider（`core/prefetch.go`）：时机是连接中订阅添加或更新成功后，以及连接 10 秒后补齐列表里其他配置。proxy-provider 不预下载，因为它的 `Initial` 会按节点名关掉连接，正在运行的配置里有同名节点时会误伤。
- 重载后，代理组的选择由 mihomo 的 cachefile 按组名恢复（#32）。要不要按配置分别记住，留给「代理组页」（#22）。
- 冷启动和热切换走的是两条略有不同的路径（`hub.ApplyConfig` 和 `executor.ApplyConfig`），改 `start` 时要同时检查重载。
- 代理端口可能随配置变化。用到代理端口的功能（出口 IP）在热切换后要重新查询。
- 实现时同步更新 AGENTS.md 里「接管的配置项」的清单，以及 `docs/architecture.md` 的状态归属表。
