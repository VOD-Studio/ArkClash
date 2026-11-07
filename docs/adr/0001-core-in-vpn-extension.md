# 0001 内核以 c-shared 库运行在 VPN 扩展进程

- 状态：已采纳（2026-11-06）

## 背景

同类客户端的主要问题是打开慢、费电、不稳定：内核和界面绑在一起，界面被系统回收，代理就断；靠"自动恢复内核"补救又带来卡顿和耗电。HarmonyOS NEXT 不允许应用执行独立的二进制文件，内核只能以共享库形式加载。

## 决定

- mihomo 编成 `libclash.so`（`-buildmode=c-shared`），通过 NAPI 桥 `libarkclash.so` 只在 `ClashVpnAbility` 所在的 VPN 进程里加载。
- UI 进程不加载内核，只通过 controller 访问。
- TUN 由 `core/tun.go` 单独创建和持有，不走配置文件里的 `tun` 段。

## 后果

- VPN 开启期间系统保活扩展进程，界面退出或被杀都不影响代理。
- UI 进程冷启动不需要加载 61MB 的内核库。
- 跨进程交互只能走 controller 和文件通道（见 0003），没有直接的函数调用。
- 切换、重载配置时 TUN 不重建，连接不断。
