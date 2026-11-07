# 0008 Go 出站逐 socket 绑定当前物理网络

- 状态：已采纳（2026-11-07）
- 取代：[0004 按 UID 把本应用排除在 VPN 之外](0004-exclude-self-by-uid.md)

## 背景

`protectProcessNet()` 和应用排除名单没有完整覆盖 Go 通过系统调用创建的 socket。真机持续运行时，默认 DoT 上游的 DIRECT 出站重新进入 TUN，gVisor 完成握手后又建立下一条 DIRECT 出站，递归产生连接、缓冲区和 goroutine。一次受控实验在开启保护前记录到 20,284 条 TUN/853 连接、40,695 个 goroutine；GC 在正常运行，不能回收仍被连接引用的对象。

只开启逐 socket 网络绑定，约 15 秒后 goroutine 降至 73，49 次原生绑定全部成功，后续不再出现连接风暴。该实验未修改订阅、DNS 上游或中继实现。

## 决定

- `core/socket.go` 在包初始化时设置 mihomo 的 `dialer.DefaultSocketHook`，覆盖内核经该拨号层创建的 TCP、UDP 和 ICMP socket。
- 在 connect/send 前，通过 Network Kit 原生 API 查询当前默认网络，再用 `OH_NetConn_BindSocket` 绑定 socket。VPN 进程继续保留进程保护和应用排除名单，当前默认网络为物理网络。
- 查询或绑定失败就返回错误，不回退到未保护的出站。
- 每个新 socket 查询当前网络，不缓存 netId，避免 Wi-Fi/蜂窝切换后的旧网络句柄。调用留在 Go goroutine 内，不回调 ArkTS、不阻塞界面主线程。
- 界面进程保留直连语义；需要经过代理的界面请求显式使用内核 HTTP 代理端口。

## 后果

- 内核链接公开的 `libnet_connection.so`，不依赖私有系统接口，不新增进程间通道。
- 不通过定时 GC、强制内存上限或修改 DNS 目标掩盖连接递归。
- 新 socket 增加原生网络查询和绑定调用；验收必须同时观察连接可用性、连接建立耗时和内存曲线。
- 修复包真机验证：Google HTTPS 204 请求成功，TCP 连接到本机转发端口约 0.25 ms，完成 TLS 约 1.17 s，总计约 1.44 s。浏览器请求在 `make log` 中命中代理；日志证据仅保留命中计数，不记录节点信息。这是一次链路测量，不是与其他客户端的延迟基准。
- 同一 VPN 进程连续观察超过 3 分钟，RSS 约 118–127 MiB，未出现默认 DoT 的 TUN 连接风暴。首页前台的一次系统 PSS 快照：UI 约 59 MiB、VPN 约 78 MiB。RSS、PSS 和 Go 堆不能混为同一指标；首页现有总数仍是内核 RSS 与界面 PSS+SwapPss 的混合值，不用于跨客户端基准。
- 本轮未测 8 小时待机耗电和 24 小时稳定性，不据此宣称这两个产品指标达标。
