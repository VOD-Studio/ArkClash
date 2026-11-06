# 0004 按 UID 把本应用排除在 VPN 之外

- 状态：已采纳（2026-11-06）

## 背景

内核自己的出站连接如果又进了 VPN，就会形成回环。官方的 `VpnConnection.protectProcessNet()` 只对经过 libc 创建的 socket 生效，Go 直接发系统调用，真机上内核的 DNS 查询全部超时。逐个 socket 调 `protect(fd)` 需要从 Go 回调到 ArkTS 的异步接口，每个连接都要多一次跨进程调用，又慢又耗电。

## 决定

`VpnConfig.blockedApplications` 填本应用的包名，由系统按 UID 在路由层面排除。`protectProcessNet()` 保留，不影响结果。

## 后果

- 内核流量不会回环，所以可以关闭 mihomo 的回环检测（`core/loopback.go`），绕开 netlink 限制。
- App 自己的流量（下载订阅）走直连；以后要支持"通过代理更新订阅"，可以显式使用内核的 HTTP 代理端口。
- 做分应用代理时，"绕过这些应用"的列表里必须始终包含本应用；`trustedApplications` 和 `blockedApplications` 互斥。
