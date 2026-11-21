# 配置与跨进程契约测试

| 命令 | 执行内容 |
| --- | --- |
| `make test` | 全部宿主回归，包括 Go 内核测试和用 Node 执行的 ArkTS 纯逻辑用例 |
| `make test TESTS='contracts core'` | 共享夹具对应的 ArkTS 用例和核心宿主回归 |
| `make test TESTS=go` | 纯 Go 备份包测试，禁用 cgo，可以在没有 DevEco 和 `libclash.so` 的机器上运行 |
| `make test TESTS=local` | 在 macOS 或 Windows 的 DevEco 环境运行 Hypium，Linux 明确报告 `SKIP` |

Local Test 通过 `entry` 模块运行。DevEco 会执行该模块的构建前置任务，包含 CMake，首次运行需要准备同一 ABI 的 `make core` 产物。Windows 从配置有 DevEco Studio 的 Bash 环境运行，并按 [环境搭建](fork-setup.md) 设置 `DEVECO_HOME`。测试用的模块来自同一份 JSON，运行结束后自动移除。执行结果以 Hypium 的用例报告为准。 [DevEco Local Test](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-local-test/)

## 夹具和覆盖

夹具在 [core/internal/testdata/contracts.json](../../core/internal/testdata/contracts.json)，使用合成名称与保留域名。

- 设置用例执行 ArkTS 请求序列化和校验、Go 逐字节解码、HTTP 处理及设置回读。它检查默认值、跨 UTF-8 字符边界读取、长整数字符串修订、显式 `false` 和错误字段类型。
- 配置用例执行 ArkTS 配置摘要和 Go 的实际配置解析。标准配置合并配置级和全局规则，脚本先生成出站供附加规则引用，自定义配置直接使用原规则。Go 用例检查最终规则顺序与目标。
- 归档用例检查纯 Go ZIP 写入的产品标识、版本、字符串修订及文件的字节数和 SHA-256。

#59 的初始规格还列出 Unix NDJSON、共享 Store manifest 和字符串流量计数。当前分支使用 controller HTTP/WebSocket、应用沙箱文件和备份归档格式。这些测试按已实现的协议取样。

## 验证记录

2026-11-20 在 Linux x86_64 上用 API 26 Command Line Tools 验证。临时副本把请求中的 `delayTimeout` 从数字改为字符串后，Go 解码和 ArkTS 校验均失败。把全局规则移到配置级规则之前后，Go 的标准与脚本配置用例均报告顺序不符。原始夹具和变换实现通过。

`make test` 通过 243 项顶层宿主回归，纯 Go 入口、`make core`、`make hap` 和 `make lint` 均通过。Codelinter 报告 0 个错误，本机缺少 shellcheck 和 actionlint，两项已跳过。

DevEco 编译了 Local Test 用例，Previewer 在 Linux 报告平台不受支持。macOS 或 Windows 的 Hypium 执行记录仍待补齐。 [DevEco Hvigor FAQ](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-hvigor-faqs/)
