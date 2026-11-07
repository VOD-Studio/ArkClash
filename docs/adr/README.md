# 架构决策记录（ADR）

记录"为什么这样做"。代码注释只写现在做什么、有什么坑，选择的理由和被否决的方案写在这里。

格式：编号递增，文件名 `NNNN-简述.md`，包含「状态 / 背景 / 决定 / 后果」。推翻一个决定时新写一份 ADR，并把旧的状态改成「已被 NNNN 取代」。

| 编号 | 标题 | 状态 |
|---|---|---|
| [0001](0001-core-in-vpn-extension.md) | 内核以 c-shared 库运行在 VPN 扩展进程 | 已采纳 |
| [0002](0002-patched-go-toolchain.md) | 用打补丁的 Go 工具链编译内核 | 已采纳 |
| [0003](0003-ui-core-via-external-controller.md) | UI 通过 external-controller 和文件通道与内核通信 | 已采纳 |
| [0004](0004-exclude-self-by-uid.md) | 按 UID 把本应用排除在 VPN 之外 | 已被 0008 取代 |
| [0005](0005-gvisor-default-stack.md) | TUN 默认使用 gVisor 协议栈 | 已采纳，待真机数据复核 |
| [0006](0006-layered-ci.md) | 分层 CI，单一必需检查，发版只构建一次 | 已采纳 |
| [0007](0007-min-harmonyos-7.md) | 最低支持 HarmonyOS 7（API 26），界面以 UI Design Kit 为准 | 已采纳 |
| [0008](0008-bind-core-sockets-to-physical-network.md) | Go 出站逐 socket 绑定当前物理网络 | 已采纳 |
