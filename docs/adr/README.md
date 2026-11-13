# 架构决策记录（ADR）

记录"为什么这样做"。代码注释只写现在做什么、有什么坑，选择的理由和被否决的方案写在这里。

格式：编号递增，文件名 `NNNN-简述.md`，包含「状态 / 背景 / 决定 / 后果」。推翻一个决定时新写一份 ADR，并把旧的状态改成「已被 NNNN 取代」。

| 编号 | 标题 | 状态 |
|---|---|---|
| [0001](0001-core-in-vpn-extension.md) | 内核以 c-shared 库运行在 VPN 扩展进程 | 已采纳，生命周期结论由 0012 修正 |
| [0002](0002-patched-go-toolchain.md) | 用打补丁的 Go 工具链编译内核 | 已采纳 |
| [0003](0003-ui-core-via-external-controller.md) | UI 通过 external-controller 和文件通道与内核通信 | 现行实现，由 0009 扩展；计划由 0013 替代 |
| [0004](0004-exclude-self-by-uid.md) | 按 UID 把本应用排除在 VPN 之外 | 已被 0008 取代 |
| [0005](0005-gvisor-default-stack.md) | TUN 默认使用 gVisor 协议栈 | 已采纳，待真机数据复核 |
| [0006](0006-layered-ci.md) | 分层 CI，单一必需检查，发版只构建一次 | 已采纳 |
| [0007](0007-min-harmonyos-7.md) | 最低支持 HarmonyOS 7（API 26），界面以 UI Design Kit 为准 | 已采纳 |
| [0008](0008-bind-core-sockets-to-physical-network.md) | Go 出站逐 socket 绑定当前物理网络 | 已采纳 |
| [0009](0009-arkclash-commands-on-controller.md) | ArkClash 自有命令挂在 controller 上 | 现行实现；通道和写入交接计划由 0013、0017 替代 |
| [0010](0010-hot-switch-reload-in-vpn.md) | 热切换由 VPN 进程重载配置 | 现行实现，管线计划由 0014 替代 |
| [0012](0012-core-host-standby-and-forwarding.md) | 内核在 VPN 扩展中预热，启动意图与实际转发分开 | 目标决策，待平台门禁及实现 |
| [0013](0013-core-channel-unix-socket-rpc.md) | 内部命令与推送使用沙箱 Unix 套接字 | 目标决策，待实现；替代 0003 和 0009 通道 |
| [0014](0014-config-pipeline-in-go.md) | 配置变换、候选准备和运行态提交分离 | 目标决策，待实现 |
| [0015](0015-settings-file-and-effect-paths.md) | 设置以事务快照保存，生效路径在 Go 显式声明 | 目标决策，待实现 |
| [0016](0016-mihomo-hook-patch.md) | 完整观测事件使用受控的 mihomo 构建期补丁 | 目标决策，待实现及回归验证 |
| [0017](0017-revisioned-file-store.md) | 配置文件使用带版本的事务清单 | 目标决策，待实现及文件锁验证 |

0011 的编号已由并行的节点选择工作预留，本分支不覆盖其草稿。0012–0017 是第一阶段实现指导，不表示现有代码已经切换。规格和进度只在 GitHub Issues 维护：

- [实施地图 #53](https://github.com/VOD-Studio/ArkClash/issues/53)：完整工单、父子归属、阻塞依赖和建议顺序。
- [产品规格 #54](https://github.com/VOD-Studio/ArkClash/issues/54)：功能矩阵、默认值、差异、性能测法和签收门槛。
- [核心实现合同 #55](https://github.com/VOD-Studio/ArkClash/issues/55)：状态机、RPC、文件事务、配置管线、事件与恢复。
- [手机页面规格 #56](https://github.com/VOD-Studio/ArkClash/issues/56)：导航、交互、设置、系统入口和完整验收。
- [配置与数据规格 #57](https://github.com/VOD-Studio/ArkClash/issues/57)：配置、规则、脚本、自定义内容、资源、备份及迁移。
