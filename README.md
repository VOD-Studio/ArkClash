# ArkClash

原生 HarmonyOS NEXT 代理客户端，内核为 [mihomo](https://github.com/MetaCubeX/mihomo)，交互参考 [FlClash](https://github.com/chen08209/FlClash)。

## 目标

| 问题 | 做法 |
|---|---|
| 打开慢 | UI 进程不加载内核，先渲染缓存状态，内核状态异步获取 |
| 费电 | 不轮询；关闭手机上无意义的进程查找；按需订阅流量/连接 |
| 不稳定 | 内核跑在 VpnExtensionAbility 进程，UI 被杀不影响代理；TUN 由我们自己持有，切换配置不重建 |
| 连接慢 | DNS 默认 fake-ip；协议栈用真机数据选默认值 |

每个版本在同一台设备上与同类客户端对比：冷启动耗时、8 小时待机耗电、新连接延迟、24 小时内核不重启。

## 架构

```
UI 进程 (EntryAbility, ArkUI)
  │  HTTP 127.0.0.1:19090 + secret（mihomo external-controller）
  ▼
VPN 进程 (ClashVpnAbility, VpnExtensionAbility)
  ├─ vpnExtension: protectProcessNet() + create() → TUN fd
  └─ libarkclash.so (NAPI) → libclash.so (mihomo, Go c-shared)
       └─ sing-tun gVisor 栈读写 TUN fd
```

两进程通过应用 `filesDir` 下的 `runtime.json` 共享配置路径与 controller secret。

| 目录 | 内容 |
|---|---|
| `core/` | Go 封装层，导出 C API（`arkclash.h`） |
| `entry/src/main/cpp/` | NAPI 桥接，start/stop 在工作线程执行 |
| `entry/src/main/ets/vpn/` | VpnExtensionAbility，持有 TUN 与内核 |
| `entry/src/main/ets/common/` | UI 侧控制、订阅下载、两进程共享状态 |

## 构建

依赖：DevEco Studio（HarmonyOS SDK API 26）、Go 1.26+。设备需 API 22+（`protectProcessNet`）。

```sh
scripts/build-core.sh   # 交叉编译 mihomo → entry/libs/arm64-v8a/libclash.so（自动准备打过补丁的 Go 工具链）
scripts/fetch-geodata.sh  # 下载 Geo 数据到 rawfile/geo/，随 HAP 打包
```

之后用 DevEco Studio 打开项目，在 File → Project Structure → Signing Configs 里用华为账号自动签名，连接真机运行。

查看日志：

```sh
hdc hilog | grep -E "ArkClashCore|ClashVpnAbility"
```

## 进度

- [x] M1：mihomo 交叉编译、NAPI 桥接、VPN 扩展、订阅下载、连接/断开
- [x] M1 真机验证（Pura 70 Ultra，API 26）
- [ ] 配置热切换（不重建 TUN）
- [ ] 代理组 / 节点选择 / 测速
- [ ] 连接、日志、流量（推送式）
- [ ] 多订阅管理与自动更新
- [ ] IPv6、分应用代理
- [x] 内置 Geo 数据，避免首次启动下载

## 许可证

GPL-3.0，与 mihomo、FlClash 一致。
