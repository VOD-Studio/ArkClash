# 0003 UI 通过 external-controller 和文件通道与内核通信

- 状态：已采纳（2026-11-06）

## 背景

内核在 VPN 进程里（0001），UI 在另一个进程里。`VpnExtensionAbility` 不支持 `connect` 方式的 IPC。

## 决定

- 运行时的查询和操作全部使用 mihomo 自带的 external-controller（REST + WebSocket），监听 `127.0.0.1:19090`，每次连接时由 UI 生成随机 secret。
- 启动前的参数交接和启动失败的回报用 `filesDir` 下的文件（`shared/Runtime.ets`），因为扩展进程也可能被系统直接拉起，拿不到 UI 传的 Want 参数。

## 后果

- 节点、连接、日志、流量等功能都可以直接复用 mihomo 的 API 和数据格式，不需要自己写 IPC。
- 本机其他应用能连到这个端口，但没有 secret 无法调用；secret 只存在应用沙箱里。
- ArkClash 自己的命令（比如按 `applyOverrides` 重新加载配置）没法通过 mihomo API 下发，到时候需要新增通道（见 architecture.md「后续演进的约束」）。
