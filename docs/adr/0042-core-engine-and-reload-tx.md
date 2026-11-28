# ADR-0042：核心状态机（Engine）、ReloadTx 与子系统单向锁序

## 状态

已采纳（宿主回归、`-race` 竞态门禁与架构检查通过；`core/lib.go` 纯转发改动随 [ADR-0040](0040-core-build-tags-and-host-tests.md) 待 OHOS NDK 双 ABI 与真机门禁联合验收）。

## 背景

在阶段一（[ADR-0040](0040-core-build-tags-and-host-tests.md)）和阶段二（[ADR-0041](0041-core-internal-deep-modules.md)）完成构建标签隔离与首批 `core/internal/*` 深度模块抽离后，根包 `core/` 仍存在四类并发与可维护性风险：

1. **包级全局状态散落**：近 20 个根包文件直接读写全局 `mu` 与散落的生命周期、配置、代理表和去重表变量，写后漏发快照或跨函数持锁容易引入数据竞态（例如 `fetch`/`prefetch` 曾无锁读取 `current.HomeDir`，且 `prefetch` 调用 `config.UnmarshalRawConfig` 读取非原子的 `geodata.GeodataMode`）。
2. **热切换与设置回滚分支分裂**：`applyReloadLocked` 依赖 `wait == nil` 暗含「是否已应用新配置」，而设置文件改名失败且回滚重解析失败时，各调用路径对失败状态和业务入口的处置不一致。
3. **子系统锁方向倒置**：`diagnostics`（9 处）与 `geo`（6 处）在后台协程、定时器或 HTTP 处理器中直接获取核心锁 `mu`，使锁顺序难以静态证明，且备份恢复改变 `CaptureLogs` 后未自动同步日志采集器。
4. **平台入口耦合与缺少竞态门禁**：`core/lib.go`（`//go:build ohos`）直接操作核心锁与快照变量；CI 宿主测试尚未运行 `-race`。

按 GitHub Issue #127 评审结论，本阶段聚焦状态机收口、事务统一、子系统锁倒置与门禁落地；目录拆包（原 Wave 3D）留待核心状态机稳定后另立独立 issue，上游 mihomo 非原子全局变量也单独立项，不在本阶段修改上游依赖。

## 决定

### 1. `coreEngine` 单一状态容器与 `core/lib.go` 纯转发

- 引入 `core/engine.go` 中的 `coreEngine`（单例 `eng`），收口核心生命周期与运行身份、平台入口句柄、代理身份表（`proxyIdentityTable`）、选择去重表（`selectionDedupLog`，其中 `panelOpSeq` 单调递增永不复位）、测速取消表（`activeDelayRegistry`）及下游子系统句柄（`providers`、`diag`、`geo`、`routes`）。
- 唯一持锁原语为 `e.withState(fn)` 与 `e.withLifecycle(fn)`，借助 `defer` 后进先出顺序保证即便回调 panic 也先释放 `e.mu`，再执行 `tx.deferUnlock` 登记的异步 join（例如子系统 `wait()`），避免锁死内核。
- `core/lib.go`（`//go:build ohos`）仅保留参数编解码与对纯 Go 函数（含 `setVpnStateFromHost`、`runtimeStatusJSON`）的转发，不再引用 `eng` 或核心锁，使后续纯 Go 重构无需反复触碰 Cgo 边界。

### 2. 两层只读快照与 `startOptions` 不可变约定

- **Tier 1 `runtimeView`**：由 `publishRuntimeLocked()` 在持有 `e.mu` 的提交点原子整块替换，承载高频无锁读路径（`Status`、`HomeDir`、`StoreGeneration`、`CaptureLogs`、`DelayTimeout`）。原独立缓存 `runningID` 并入 `runtimeView`，由宿主测试钩子 `engineUnlockCheck` 在每次 `withState` 解锁前校验快照与核心状态一致，防止漏发布或快照漂移。
- **Tier 2 `configSpec`**：由 `e.ConfigSpec()` 持短锁返回 `BootID`、`ConfigRevision` 与 `startOptions` 的浅拷贝，供锁外慢路径（运行时配置预览、QuickJS 脚本执行、规则集预检、订阅下载与预检）读取。
- **不可变不变量**：`startOptions` 及其嵌套设置结构体中的所有切片和 map（如 `Hosts`、`Rules`、`Profiles`、`Items`、`ExitTargets`）只允许整体替换，严禁原地修改，从而在无深拷贝开销的前提下保证 `configSpec` 锁外读取并发安全。

### 3. 统一 `ReloadTx` 与配置回滚失败策略

- 将热切换提交统一为 `tx.CommitReload(plan reloadPlan) (applied bool, err error)`，以显式 `applied` 布尔值区分「前置关闭业务入口即失败」与「已应用新配置但后续步骤失败」，消除 `wait == nil` 的隐式哨兵语义，并删除不再使用的辅助函数。
- 将配置回滚统一为 `tx.RollbackReload(previous, fallbackInbound)`，并与 `tx.CommitSettingsFile` 串联：若原子改名失败，先尝试重解析并回滚至 `previous`；若重解析或回滚热切换也失败，统一进入失败状态（记入 `cleanupFailure`、关闭业务入口并停止 TUN、调用 `setCurrentLocked(previous)` 将快照 `Forward` 置为 `"failed"`），避免内存运行配置与磁盘文件静默分叉。

### 4. 严格单向锁 DAG 与 `diagnosticsHub` / `geoHub` 锁倒置

全内核严格遵守单向锁序，禁止任何下游子系统反向获取核心锁：

```text
e.lifecycle -> e.mu -> { providers.mu, geo.mu, diag.mu -> collector.mu -> diag.statsMu }
```

- **`diagnosticsHub`**：由 `coreEngine` 持有，引擎在 `Start`、`BeginReload`、`EndReload(diagIdentity)`、`SetCaptureLogs`、`Stop` 节点按值下推运行身份与采集开关；`core/diagnostics*.go` 消除全部 9 处 `eng.mu` 锁调用，统计会话与 `statsMu` 并入 hub，且 `EndReload` 统一同步 `CaptureLogs`，顺带修复备份恢复修改日志开关后日志采集器未同步的问题。
- **`geoHub`（`geoManager`）**：原包级 `activeGeo` 迁入 `coreEngine.geo`；定时器回调、worker 收尾、`beginAttempt` 与 `POST /arkclash/geo/update` 均改为只锁 `m.mu`，消除全部 6 处核心锁直接调用。
- **Geo 设置与热换提交经引擎向下进入**：
  - `POST /arkclash/geo/settings` 经 `e.ApplyGeoSettings`（`e.mu -> m.mu`）统一校验磁盘修订、下推设置并同步 `current.Geo` 与 mihomo 全局 URL，与备份恢复共用单向下推路径。
  - 候选文件落盘与 reader/缓存热换在锁外完成下载、哈希、校验后，经 `e.CommitGeoSwap`（`e.mu -> m.mu`）串行提交并在内容变化时推进运行快照代次。保持该提交经过 `e.mu`，是因为上游 mihomo 在 `ParseRawConfig` 中调用的 `geodata.Init*` 会对缺失或损坏的 Geo 文件执行非原子 `os.Remove` + `os.OpenFile`，必须与配置热切换串行隔离。

### 5. 架构门禁收紧与 CI `-race` 覆盖

- 扩展 `scripts/ci/check-core-arch/main.go`，在 `make lint CHECKS=go` 中强制执行三条 AST 约束：
  1. 非测试根包文件除 `core/engine.go` 外禁止访问 `eng.mu`、`eng.lifecycle` 或 `coreEngine` 方法接收者的 `mu`、`lifecycle` 字段；
  2. `core/lib.go` 禁止直接引用 `eng`；
  3. 根包非哨兵错误（`err* = errors.New(...)`）、非不可变正则/地址常量的顶层 `var` 实行 fail-closed 白名单并正向校验陈旧条目，防止新增散落全局状态。
- 在 `.github/workflows/ci.yml` 的 `core-test` 任务中，于全量非竞态宿主回归之后追加 `CORE_RACE=1` 竞态回归步骤，覆盖全部 6 个 `core/internal/*` 包、6 个 mihomo 白盒测试包与根包 157/159 项测试；仅通过 `CORE_TEST_SKIP` 显式跳过 2 项命中上游 mihomo 非原子全局变量（`inbound.SetSkipAuthPrefixes`、`resolver.DefaultHosts`、`resource.SetETag`、`http.SetUA`）的用例，待独立上游补丁 issue 解决后移除跳过列表。

## 后果

- **正面**：核心状态与锁顺序收敛到单一文件并可由 AST 门禁自动核对；热路径无锁读、写路径 panic 安全且事务语义统一；`diagnostics` 与 `geo` 的并发竞态和备份恢复日志开关不同步问题得到回归测试与 CI `-race` 持续防护。
- **代价与约束**：
  - 新增配置设置结构时必须遵守 `startOptions` 切片/map 整体替换的不变量，不可原地修改已发布的 `configSpec`。
  - 根包业务文件拆分至 `core/internal/*`（原 Wave 3D）与上游 mihomo 全局变量原子化改造仍需后续独立 issue 跟进。
  - `core/lib.go` 的改动仍需在具备 OHOS NDK 与真机的环境完成双 ABI 构建、`make core-smoke` 与真机代理验收。
