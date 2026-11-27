# 0040 用 ohos 构建标签隔离内核平台代码并原地运行宿主回归

## 状态

已采纳（宿主回归、Go 架构门禁与 fail-closed 验证通过；OHOS NDK 双 ABI 符号/体积对照、`make core-smoke` 与真机门禁待验收）。关联 Issue #125。

## 背景

原有 `core/` 中，`core/api.go` 混放了 controller 路由、事件推送、命令桥、经内核下载与 5 个 `//export` 导出；4 个 OHOS NDK Cgo 文件（`hilog.go`、`socket.go`、`system_dns.go`、`tailscale_network.go`）和 `loopback.go` 均无构建标签。这带来三个直接问题：

- `scripts/verify-core.mjs` 无法在 `core/` 原地跑测试，只能把 37 个业务源码与 30 个测试文件拷入临时沙箱、用正则从 `core/api.go` 抠出部分函数，并在测试里另写假 `startTun`/`stopTun`/`emit` 夹具，真实 `api.go` 路由注册、`tun.go` 参数校验与一次性关闭逻辑从未进入宿主回归。
- 准备补丁版 `mihomo`、`tailscale`、`gVisor` 与临时 `go.mod` 的逻辑在 `build-core.sh`、`lint.sh`（vet 与 govulncheck）、`ci/build-codeql.sh` 和 `verify-core.mjs` 中重复 5 份，且 gVisor 补丁不一致。
- CI 未运行内核宿主回归，`lint.sh` 在缺少 OHOS NDK 时也会整段跳过 `go vet`。

## 决定

- **保持 `package main`，以 `//go:build ohos` 实现隔离与 fail-closed**：第一批不拆 `package core` + `cmd/clash`，不移动 `core/backupstore/`。将全部 16 个公开 `//export ArkClash*` 与 `func main()` 收口到带 `//go:build ohos` 的 `core/lib.go`，并为 `hilog.go`、`socket.go`、`system_dns.go`、`tailscale_network.go`、`loopback.go` 添加 `//go:build ohos`（不使用 `*_ohos.go` 后缀，防止未来 Go 新增 `GOOS=ohos` 时在当前 `GOOS=linux` 构建中被隐式排除）。缺 `ohos` 标签构建 `-buildmode=c-shared` 时因缺少 `main()` 直接编译失败（fail-closed），不提供无保护的空桩；`build-core.sh`、`lint.sh`（vet 与 govulncheck）和 `ci/build-codeql.sh` 统一传 `-tags with_gvisor,ohos`。
- **拆净 `core/api.go` 并统一补丁 `-modfile` 准备**：将 `core/api.go` 拆为纯 Go、零 `import "C"` 的 `api.go`（路由注册、核心接口与共享 HTTP/WebSocket 辅助）、`fetch.go`、`events.go`（提供 `subscribeEvents(buffer int)`，生产代码传 16）和 `commands.go`（纯 Go `commandDispatcher`）。抽出 `scripts/prepare-core-modfile.sh <目标目录>` 供 5 处入口及编辑器 `gopls` 共用，统一包含 mihomo、tailscale 与 gVisor 补丁。
- **最小测试替换点与原地宿主回归**：`core/tun.go` 引入 `tunHandle` 接口与 `newTunListener` 构造器（失败时显式返回无类型 `nil`，避免 typed-nil 落入 `tunListener != nil` 判断），测试通过 `setHostTun` 同步复位 `tunCloseAttempted`/`tunCloseErr` 并执行真实 `startTun`/`stopTun`/`subscribeEvents`。30 个项目宿主测试与 Geo 测试夹具迁回 `core/`（5 个 mihomo 白盒测试留在 `scripts/`），`scripts/verify-core.mjs` 直接在 `core/` 运行 `go test -modfile`，`make test TESTS=core` 不再依赖 `ohpm` 或 TypeScript 编译器。
- **CI 宿主回归与 Go 架构门禁**：`.github/workflows/ci.yml` 新增 `core-test` 任务（`ubuntu-latest` 执行 `make test TESTS=core`）并计入「CI 通过」汇总；`.github/workflows/codeql.yml` 排除 `core/**/*_test.go` 与 `core/testdata/**`；新增 `scripts/ci/check-core-arch/main.go` 并挂入 `make lint CHECKS=go`，用 `go list -json` 与 `go/parser` 强制双标签文件归属、宿主零根包 Cgo、`backupstore`/`internal/*` 零 mihomo 传递依赖、`init()` 白名单、`//export` 收口与禁止 `*_ohos.go` 命名。无 NDK 环境也运行非 `ohos` 文件的宿主 `go vet`。

## 后果

- 纯 Go 业务代码仍调用补丁版 mihomo/tailscale API，在 `core/` 原地运行 `go test` 或配置 `gopls` 时仍需通过 `scripts/prepare-core-modfile.sh` 传入 `-modfile`（不改动 `core/go.mod`）。
- CI 每个非纯文档 PR 都会自动执行全部 30 组内核宿主回归、mihomo 白盒回归和 Linux TUN fd 回归，并持续守住 Go 架构边界。
- 如后续出现第二个消费方需要导入内核 Go 包，再另写 ADR 评估拆包，不在本决策内提前引入包边界与锁范围变动。
- ARM64 / x86_64 双 ABI 的导出/导入符号与体积对照、`make core-smoke`，以及真机代理命中、Wi-Fi/蜂窝切网和 20 轮连断仍按真机门禁验收。
