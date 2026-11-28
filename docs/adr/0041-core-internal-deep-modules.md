# 0041 按窄接口与独立可测性向 core/internal 抽取深度模块

## 状态

已采纳。扩展 [ADR-0040](0040-core-build-tags-and-host-tests.md)，关联 Issue #126。

## 背景

[ADR-0040](0040-core-build-tags-and-host-tests.md) 确立了保持 `package main` 与 `//go:build ohos` 的平台隔离和原地宿主回归方案，并记录「若出现第二个消费方再评估拆包」。完成该阶段后，`core/` 根目录仍有 47 个非测试 `.go` 文件（12,146 行）平铺在同一命名空间中。

进一步按 AST 依赖与锁序分析，发现其中存在两类天然边界清晰、完全不碰核心锁 `core.mu` 的代码：

- 零全局状态的纯引擎（分享链接编解码、规则集格式嗅探与 MRS 编译，以及 `providers` 与 `rule_sets` 共用的规则集标识和 `HasNonPortableChild` 规则）；
- 自带独立 `sync.Mutex`、只需按值接收运行身份（`bootId`/`configRevision`/`profile`/`homeDir`）的独立子系统（运行中 Provider 管理）及约 50 行、零 mihomo 依赖的控制面 HTTP/WebSocket 公共协议辅助。

相反，`geo` 与 `diagnostics` 目前在各自多处直接先加 `core.mu` 再加内部锁，`platform` 的 5 个 `init()` 与 `//export` 位于宿主测试覆盖不到的 OHOS NDK 路径，过早拆出只会把裸锁包成闭包或增加平台初始化风险。

## 决定

- **继续保持 `package main` 与 `core/backupstore/` 原路径**：仍不拆 `cmd/clash`，拆包动机明确为「独立可测性、消除横向耦合与编译器级封装」，而不是追求根包文件数量指标。
- **阶段二仅抽取零 `core.mu` 的深度内部包**：
  - **Wave A**：抽出 `core/internal/proxylink`（`Encode`、`Decode`）与 `core/internal/ruleset`（`DetectFormat`、`Compile`、`ValidateMRS`、`ValidID`、`ManagedName`、`IsManagedName`、`HasNonPortableChild`），切断 `providers` 与 `rule_sets`、`added_rules` 间的横向符号引用。
  - **Wave B**：抽出零 mihomo 的 `core/internal/ctrl`（`WriteError`、`UpgradeWebSocket`、`WriteTextFrame`）与零 `core.mu` 的 `core/internal/providers`（`Hub.Reset(Identity, cfg)` 按值注入，`RegisterRoutes` 持有自身 4 个 HTTP/WS 路由；`providers_test.go` 拆为包内单测与根包集成测试）。
- **暂缓 `geo`、`diagnostics`、`platform`**：前两者留待阶段三完成 `Engine` 状态机与事务接口设计后再拆；6 个 `ohos` 平台文件继续留在 `core/` 根包，避免无收益地改变 `init()` 执行顺序与导出符号归属。
- **未登记即失败的 `internal/*` DAG 门禁**：扩展 `scripts/ci/check-core-arch/main.go`，对 `core/` 下所有包实行白名单登记（未登记即失败），强制单向内部依赖与 `backupstore`、`internal/backup`、`internal/script`、`internal/ctrl` 零 mihomo 传递依赖。
- **防退化测试清单校验**：每波迁移前后对比 `go test -list='^Test' . ./internal/...`，确保测试用例只增不减；`scripts/tests/core.test.mjs` 自动执行全部 `core/internal/...` 包测试。

## 后果

- 纯引擎与独立子系统可脱离根包完整夹具单独执行 `go test` 与 `-race` 回归，并由 CI `core-test` 自动覆盖。
- 新增 `core/internal/*` 包必须同步在 `scripts/ci/check-core-arch/main.go` 登记依赖白名单并更新 `docs/architecture.md`。
- Wave A 与 Wave B 均不触碰 `//go:build ohos` 文件或 C ABI 入口，验证以宿主回归、架构门禁与 CI NDK `core` 构建为主；阶段一（#125）的真机门禁仍需独立闭环。
- 阶段三（收敛核心裸全局状态与 `Engine` 接口）将另开 issue 先评审接口，再决定后续拆包形态。
