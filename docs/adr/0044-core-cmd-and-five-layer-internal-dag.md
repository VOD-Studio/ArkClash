# ADR-0044：内核目录收口（cmd/ 入口与 5 层单向 internal DAG）

## 状态

已采纳（宿主全量回归、`-race` 竞态回归、Linux TUN fd 容器测试、CodeQL 分析构建、双 ABI OHOS NDK 构建与导出符号核对及全包架构门禁负向单测均已通过；真机 `make core-smoke` 与实网代理转发待连接真机/模拟器后复核）。

## 背景

完成阶段一至阶段三（[ADR-0040](0040-core-build-tags-and-host-tests.md)、[ADR-0041](0041-core-internal-deep-modules.md)、[ADR-0042](0042-core-engine-and-reload-tx.md)）后，`core/` 模块已实现构建标签隔离、核心状态机与单向锁序，但代码布局仍残留五类收口问题（GitHub Issue #128）：

1. **入口与业务混居**：`core/` 根目录平铺 20 余个业务与平台 `.go` 文件，独立备份库位于 `core/backupstore/` 而非标准 `cmd/` 入口目录，无法直接从目录树辨认动态库边界与分层依赖。
2. **零核心锁子系统滞留根包**：探测（`probe`）、订阅下载与预取（`subfetch`）、诊断采集与流推送（`diagnostics`）、Geo 调度与热换（`geo`）以及纯配置解析/组装/校验（`config`）虽已不直接持有核心锁，仍与核心状态机共享同一 Go 包，编译期无法阻止回退耦合。
3. **OHOS 平台层与业务耦合**：`hilog.go` 直接调用诊断日志脱敏函数，若直接抽包会形成平台层反向依赖诊断层的错误边；且 `//go:build ohos` 与原生 Cgo 文件散落在根目录。
4. **控制面路由隐式装配与锁共享**：`api.go` 依赖包级 `init()` 自动向 mihomo 全局路由列表注册 `/arkclash/*`，测试难以按路由器实例隔离验证；外部面板（`127.0.0.1:9090`）与控制面写入路由共用的跨进程配置存储锁守卫需要单向归属，同时面板默认监听宿主机 9090 端口容易导致本机并发测试冲突。
5. **静态门禁覆盖面不足**：此前 `check-core-arch` 仅对根包检查顶层可变变量与锁边界，缺少对全部 `internal/*` 包级变量的统一白名单、拓扑无环校验以及门禁自身的负向单测。

## 决定

### 1. `core/` 零根 `.go` 文件与 `cmd/` 双动态库入口

- `core/` 根目录不再存放任何 `.go` 文件（含测试文件），仅保留 `go.mod`、`go.sum`、`arkclash.h` 与 `cmd/`、`internal/` 目录。
- `core/cmd/clash/lib.go`（`//go:build ohos`）作为 `libclash.so` 唯一 C ABI 入口与进程装配点，保留全部 16 个 `//export ArkClash*` 符号；在 `init()` 中核对 `platform.TunDNS`/`TunDNS6` 与 `engine.TunDNS`/`TunDNS6` 一致、向 `platform.StartHilog` 注入 `diagnostics.DescribeLog` 脱敏回调，并调用 `api.InstallOnce(runtimeEngine)`。
- `core/cmd/backupstore/main.go` 作为独立备份库 `libarkstore_impl.so` 入口，保留 `ArkStoreRun`/`ArkStoreFree` 两个导出符号，仅允许依赖 `internal/backup`，严格维持零 mihomo 依赖。

### 2. 5 层单向 `internal/` DAG（15 个包）

全模块内部包划分为 5 层严格无环单向依赖图：

| 层级 | 包 | 允许依赖的 `core/internal/*` | 职责 |
|---|---|---|---|
| L5 基础与平台层 | `internal/backup` | 无 | ZIP 备份、原子目录交换与 WebDAV（零 mihomo，`CGO_ENABLED=0`） |
| L5 基础与平台层 | `internal/script` | 无 | QuickJS 配置覆写脚本沙箱与执行限额（零 mihomo） |
| L5 基础与平台层 | `internal/ctrl` | 无 | controller 错误信封、原生 WebSocket 帧写入、事件总线与命令桥（零 mihomo） |
| L5 基础与平台层 | `internal/proxylink` | 无 | 分享链接与代理节点定义编解码纯引擎 |
| L5 基础与平台层 | `internal/ruleset` | 无 | 规则集标识校验、格式识别、MRS 编译校验与可移植性检查 |
| L5 基础与平台层 | `internal/ruletunnel` | 无 | 按内核当前规则与证书信任拨号的共享传输层（`DialRule`、`NewRuleTransport`） |
| L5 基础与平台层 | `internal/platform` | 无 | OHOS 平台适配（`hilog`、`socket`、`system_dns`、`loopback`、`tailscale_network`，均为 `//go:build ohos`）与纯 Go `tailscale_watch` 状态机；`hilog` 通过回调注入解耦，不依赖 `diagnostics` |
| L4 独立子系统 | `internal/providers` | `ctrl`、`ruleset` | 运行中 Provider 管理、单飞更新、本地校验替换与快照推送 |
| L4 独立子系统 | `internal/probe` | `ctrl`、`ruletunnel` | 出口与服务探测、4 槽并发控制、正文窗口扫描与跨源重定向隔离 |
| L4 独立子系统 | `internal/subfetch` | `ruletunnel` | 经内核规则下载、age 解密订阅与后台 rule-provider 预取 |
| L4 独立子系统 | `internal/diagnostics` | `ctrl` | 应用级连接/DNS/日志有界采集、诊断 WebSocket 流、仪表盘计数与动作事务 |
| L4 独立子系统 | `internal/geo` | `backup`、`ctrl`、`ruletunnel` | Geo 资源设置契约、串行可取消下载、校验热换与状态推送 |
| L3 配置域 | `internal/config` | `backup`、`geo`、`proxylink`、`ruleset`、`ruletunnel`、`script` | 零核心锁配置域：`StartOptions`、`ApplyOverrides` 与预览组装、常规/DNS/附加规则/规则集/脚本设置与自定义代理/筛选正则校验 |
| L2 核心引擎 | `internal/engine` | `backup`、`config`、`ctrl`、`diagnostics`、`geo`、`providers`、`ruletunnel` | 唯一持有 `lifecycle` 与 `mu` 锁的核心状态机、热切换与回滚事务、业务入口与 TUN 句柄、外部面板控制器、代理身份与选择事务、测速取消、Tailscale 登录及 `WithPortableMutation` 跨进程存储锁守卫 |
| L1 控制面 | `internal/api` | `backup`、`config`、`ctrl`、`diagnostics`、`engine`、`geo`、`probe`、`providers`、`subfetch` | 零 `init()` 控制面路由装配器，经 `Mount(chi.Router)` 显式挂载全部 `/arkclash/*` 路由，并由进程级 `sync.Once` 的 `InstallOnce(eng)` 幂等接入 mihomo `route` |

关键解耦取舍：

- **共享规则拨号抽离为 `internal/ruletunnel`**：使 `probe`、`subfetch`、`geo`、`config` 与 `engine` 共用统一拨号与取消契约，消除原根包隐式共享。
- **跨进程配置存储锁守卫下沉至 `engine.WithPortableMutation`**：`engine/panel.go` 与 `api/api.go` 共用同一把文件锁与存储代次校验，彻底避免 `api <-> engine` 反向依赖。
- **外部面板地址可注入**：`Engine.SetPanelAddr` 允许测试覆盖默认的 `127.0.0.1:9090`，消除宿主环境端口冲突。
- **`internal/api` 取消 `init()` 并以 `InstallOnce` 保幂等**：独立测试可直接 `api.New(eng).Mount(chi.NewRouter())` 验证路由与存储锁冲突，连续 `Start -> Stop -> Start` 也不会重复挂载 `/arkclash`。

### 3. 构建、测试与全包 fail-closed 架构门禁

- `scripts/build-core.sh` 与 `scripts/ci/build-codeql.sh` 切换编译目标至 `./cmd/clash` 与 `./cmd/backupstore`。
- `scripts/verify-core.mjs` 移除根包 `.`，将原根包集成回归及 `CORE_TEST_RUN`/`CORE_TEST_SKIP` 指向 `./internal/engine` 与 `./internal/api`，普通回归与 `CORE_RACE=1` 均完整覆盖全部 15 个 `internal/*` 包及 6 个 mihomo 白盒包。
- `scripts/ci/check-core-arch/main.go` 升级为全包架构门禁，在 `make lint CHECKS=go` 中强制执行：
  1. `core/` 根目录零 `.go` 文件（含 `*_test.go`）；
  2. `allowedInternalDeps` 自身 DAG 拓扑无环且无悬空节点；
  3. 宿主标签下无 `cmd/clash`、无多余 Cgo；OHOS 标签下 `cmd/clash` 与 `internal/platform` 文件集合精确匹配；`cmd/clash`、`cmd/backupstore` 与全部 `internal/*` 依赖白名单 fail-closed，未登记即失败；
  4. `//go:build ohos` 仅限 `cmd/clash/lib.go` 与 `internal/platform/*.go`，禁止 `*_ohos.go` 命名；
  5. 全包校验 `init()` 白名单、`//export` 位置收口（仅 `cmd/clash/lib.go`、`cmd/backupstore/main.go` 与 `internal/platform/tailscale_network.go`）及全包非不可变包级 `var` 白名单（并正向检测陈旧条目）；
  6. `internal/engine` 除 `engine.go` 外禁止经接收者或 `*Engine` 参数直接访问 `mu`/`lifecycle`。
- 新增 `scripts/ci/check-core-arch/main_test.go` 负向单测，覆盖上述全部违例分支，并由 `scripts/lint.sh` 在 `make lint CHECKS=go` 中自动执行。

## 后果

- **正面**：动态库入口（`cmd/`）、平台层（`internal/platform`）、纯配置域（`internal/config`）、独立子系统、核心状态机（`internal/engine`）与控制面（`internal/api`）在编译期与静态门禁双重隔离；181 项基线测试零丢失并新增控制面隔离与门禁负向单测；双 ABI 导出符号集与改造前逐项一致。
- **代价与约束**：
  - 新增 `core/internal/*` 子包或确需保留的包级变量，必须同步更新 `scripts/ci/check-core-arch/main.go` 与 `docs/architecture.md`。
  - 上游 mihomo 2 项非原子全局变量竞态仍沿用 `CORE_TEST_SKIP`，待后续独立上游补丁 issue 消除。
  - `core/cmd/clash/lib.go` 与 `core/internal/platform/` 变动仍需在连接真机/模拟器时完成 `make core-smoke` 与实网代理转发验收。
