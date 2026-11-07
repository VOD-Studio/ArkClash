# 架构

产品目标和性能底线见 AGENTS.md「产品底线」，平台限制见 `docs/agents/platform-pitfalls.md`，关键决策的理由见 `docs/adr/`。

## 运行时结构

```mermaid
flowchart LR
  subgraph UI["UI 进程（EntryAbility）"]
    pages["pages/"] --> features["features/*"]
    features --> client["client/CoreClient"]
  end
  subgraph VPN["VPN 进程（ClashVpnAbility）"]
    ability["vpn/ClashVpnAbility"] --> bridge["libarkclash.so（NAPI）"]
    bridge --> core["libclash.so（mihomo）"]
    core -- "订阅类命令<br/>（线程安全函数）" --> ability
  end
  sys["系统 VPN 服务"]
  client -- "HTTP / WebSocket<br/>127.0.0.1:19090 + secret<br/>mihomo API 和 /arkclash/" --> core
  client -- "filesDir 文件<br/>runtime.json / core_error.txt<br/>profiles/" --> ability
  client -- "startVpnExtensionAbility" --> sys
  sys -- "拉起 / 销毁" --> ability
  ability -- "create(VpnConfig) → TUN fd" --> sys
```

- **UI 进程**只做界面和控制，不加载内核。界面可以随时被系统回收，代理不受影响。
- **VPN 进程**由系统在 VPN 开启期间保活，持有 TUN fd 和内核，是代理的唯一运行位置。
- 两个进程之间只有两条通道（[ADR-0003](adr/0003-ui-core-via-external-controller.md)）：
  - **内核控制面**：mihomo 的 external-controller，所有运行时查询和操作（节点、连接、日志、流量）都走这里。ArkClash 自己的命令挂在同一个 controller 的 `/arkclash/` 下（`core/api.go`，[ADR-0009](adr/0009-arkclash-commands-on-controller.md)）：热切换、模式和局域网代理、运行状态由 Go 处理；订阅类命令（添加、更新、列表变更）由 Go 经 NAPI 线程安全函数转给 VPN 进程的 ArkTS（`vpn/ProfileCommands.ets`）。VPN 进程自己发起的变化经 `/arkclash/events` 推给界面。mihomo 给独立进程用的 `PUT`/`PATCH /configs`、`/restart`、`/upgrade` 由 embed 模式关掉。
  - **文件通道**：`shared/Runtime.ets` 管理的几个文件，用于启动前交接（secret、协议栈、出站模式、局域网代理）和启动失败回报；`shared/profiles/Store.ets` 管理的配置目录，存订阅和配置（格式和写入方见文件头）。
- UI 进程通过 `protectProcessNet()` 和应用排除名单保持直连；Go 出站另由 `core/socket.go` 逐 socket 绑定当前默认物理网络，避免回到 TUN（[ADR-0008](adr/0008-bind-core-sockets-to-physical-network.md)）。需要看代理出口的功能（比如首页的出口 IP）把内核的 HTTP 代理端口（配置里的 `mixed-port` 或 `port`）当普通代理用，端口号从 controller 查。这不是控制通道；配置里没开代理端口时，这类功能显示为不可用。

## 连接流程

```mermaid
sequenceDiagram
  participant UI as UI（CoreClient）
  participant Sys as 系统 VPN 服务
  participant Ext as ClashVpnAbility
  participant Core as 内核
  UI->>UI: 写 runtime.json（新 secret、模式、局域网代理）
  UI->>Sys: startVpnExtensionAbility
  Sys-->>UI: 首次弹授权框
  Sys->>Ext: onCreate
  Ext->>Sys: createVpnConnection / protectProcessNet
  Ext->>Sys: create(VpnConfig，排除本应用 UID)
  Sys-->>Ext: TUN fd
  Ext->>Ext: installGeoData（按需复制）
  Ext->>Core: start(JSON：配置、fd、controller、secret)
  Core->>Core: 解析配置、applyOverrides、启动 TUN
  loop 直到就绪或超时
    UI->>Core: GET /version
  end
  Note over Ext,UI: 启动失败时 Ext 写 core_error.txt，UI 读到后报错
```

断开：UI 调 `stopVpnExtensionAbility`，系统回调 `onDestroy`，依次停内核、销毁 VPN 连接。

## 状态归属

| 状态 | 归属 | 写入方 | 读取方 |
|---|---|---|---|
| 配置列表 `profiles/list.json`（订阅和配置的记录、当前配置） | 应用沙箱 | UI | UI、VPN 进程 |
| 配置内容、摘要、订阅状态（`profiles/` 下其余文件） | 应用沙箱 | 来自订阅的：未连接时 UI，连接中 VPN 进程；本地配置：UI | UI、VPN 进程、内核 |
| `runtime.json`（secret、协议栈、出站模式、局域网代理） | 应用沙箱 | UI，每次连接前和连接中改设置时 | VPN 进程 |
| `core_error.txt` | 应用沙箱 | VPN 进程 | UI，读后删除 |
| Geo 数据（`filesDir/*.metadb、*.dat`）和版本标记 `geo.version` | 应用沙箱 | VPN 进程，安装包里的版本变了才从 rawfile 复制 | 内核 |
| 用户设置（出站模式、局域网代理等） | UI 的 preferences | UI | UI |
| 运行时状态（节点选择、连接、流量、正在运行的配置） | 内核内存 | 内核 | UI，经 controller |

同一个应用的 UI 进程和扩展进程共享模块级的 `filesDir`。preferences 只在 UI 进程里用，扩展进程需要的信息都要落到文件通道里。两个进程都会写的文件一律先写临时文件再改名（`shared/Files.ets`），同一时刻只有一方在更新订阅，交接见 ADR-0009。

## ArkTS 分层与依赖方向

| 目录 | 职责 | 可以依赖 |
|---|---|---|
| `shared/` | 两个进程共用的代码：路径、文件读写，以及订阅更新（`shared/profiles/`，[ADR-0009](adr/0009-arkclash-commands-on-controller.md)） | 系统 Kit、`yaml` |
| `client/` | UI 访问内核的唯一入口：拉起/停止 VPN、controller 请求、数据模型 | `shared/` |
| `features/<功能>/` | 一个功能的状态、页面片段和组件（订阅、代理组、连接、日志、设置） | `client/`、`shared/`、`components/` |
| `components/` | 跨功能复用的界面组件，不带业务逻辑 | `shared/` |
| `pages/` | 路由入口，只负责把 feature 组装成页面 | 上面所有 UI 层 |
| `entryability/` | UI 进程入口 | `pages/` |
| `vpn/` | VPN 进程：TUN、内核生命周期、Geo 数据，连接期间的订阅更新和命令处理 | `shared/`、`libarkclash.so` |

规则：

- UI 层（除 `vpn/` 外的目录）不 import `vpn/`，也不 import `libarkclash.so`。
- `vpn/` 不 import 任何 UI 层目录。
- feature 之间不直接 import；被第二个 feature 用到的东西上提到 `components/`、`client/` 或 `shared/`。
- `components/` 第一次有实际内容时再建目录。
- 这些规则由 `scripts/check-arch.py` 检查（`make lint`）；新增目录时同时更新本表和脚本里的 `ALLOWED`。

## 内核层（Go）

| 文件 | 职责 |
|---|---|
| `core/lib.go` | 导出的 C API（`arkclash.h`）；`applyOverrides` 强制 ArkClash 接管的配置项；热切换 `reload` |
| `core/api.go` | controller 上的 `/arkclash/` 路由、转给 ArkTS 的命令、事件推送、经内核下载 |
| `core/prefetch.go` | 在后台预先下载配置里的 rule-provider，第一次热切换不用等 |
| `core/tun.go` | 用系统给的 fd 启动 sing-tun（gVisor 栈），独立于配置的 TUN 设置 |
| `core/socket.go` | 通过 Network Kit 原生 API 保护 Go 出站 socket，绑定失败则拒绝拨号 |
| `core/hilog.go` | 内核日志转发到 hilog |
| `core/loopback.go` | 关闭回环检测（原因见 platform-pitfalls 第 4 条） |

TUN 由 `tun.go` 单独持有，不走配置文件，所以重新加载或切换配置都不会重建 TUN（[ADR-0001](adr/0001-core-in-vpn-extension.md)）。热切换只调 `executor.ApplyConfig`，不重建 controller（[ADR-0010](adr/0010-hot-switch-reload-in-vpn.md)）。

## 构建产物

```
core/ ── scripts/build-core.sh（补丁版 Go + OHOS NDK）──► entry/libs/arm64-v8a/libclash.so
Geo 数据 ── scripts/fetch-geodata.sh ──► entry/src/main/resources/rawfile/geo/
entry/ ── hvigor（CMake 编 NAPI 桥 + ArkTS）──► HAP
```

## 后续演进的约束

- **provider 预下载**：热切换要等新配置的 provider 全部加载完。`core/prefetch.go` 在后台预先下载 rule-provider，触发方是 VPN 进程（订阅更新后、连接 10 秒后）和界面（连接中导入本地配置后，经 `POST /arkclash/prefetch`）。proxy-provider 不预下载（原因见 ADR-0010）。
- **新的 ArkClash 命令**：挂在 `core/api.go` 的 `/arkclash/` 下。内核自己能完成的由 Go 处理；要用到 ArkTS 侧逻辑的，走 `/arkclash/profiles/{name}` 这类转发路由（ADR-0009）。
- **VpnConfig 级设置**（协议栈、IPv6、分应用代理、VpnConfig 里的 DNS 地址和 MTU）不能热切换，改了只能断开重连（ADR-0010）。
- **分应用代理**：`VpnConfig` 的 `trustedApplications` 和 `blockedApplications` 互斥。"只代理这些应用"用 trusted 列表，本应用不在列表里，自然被排除；"绕过这些应用"用 blocked 列表，列表里必须始终带上本应用（[ADR-0004](adr/0004-exclude-self-by-uid.md)）。
- **流量与连接**：用 controller 的 WebSocket（`/traffic`、`/connections`、`/logs`）推送，规则见 `docs/agents/ui.md`「性能」。
- **IPv6**：要同时给 `VpnConfig` 加 IPv6 地址和路由，给 `tun.go` 加 `Inet6Address`，两边一起改。
