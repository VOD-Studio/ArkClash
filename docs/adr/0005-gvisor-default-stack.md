# 0005 TUN 默认使用 gVisor 协议栈

- 状态：已采纳，待真机数据复核（2026-11-06）

## 背景

sing-tun 提供 gvisor、system、mixed 三种栈。system 栈依赖内核 TCP 协议栈处理 TUN 流量，回包路由与本应用的 UID 排除（0004）、进程级网络绑定的交互方式没有验证过。gVisor 完全在用户态处理，只读写 TUN fd。

## 决定

默认使用 gVisor，`runtime.json` 的 `stack` 字段保留切换能力。

## 后果

- 真机上已验证可用（TCP、UDP、QUIC）。
- gVisor 的 CPU 开销通常高于 system 栈。按产品底线，需要在真机上对比三种栈的耗电和延迟，有了数据再决定是否改默认值，结论写进新的 ADR。
