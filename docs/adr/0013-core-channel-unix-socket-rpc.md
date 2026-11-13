# 0013 内部命令与推送使用沙箱 Unix 套接字

- 状态：目标决策，待实施（2026-11-13）
- 实现后替代：[0003](0003-ui-core-via-external-controller.md) 的内部 controller 通道、[0009](0009-arkclash-commands-on-controller.md) 的内部路由部分。
- 0009 的共享 ArkTS 订阅逻辑与线程安全宿主回调保留；写入交接改按 [0017](0017-revisioned-file-store.md)。

## 背景

FlClash 将外部 controller 作为用户功能，默认关闭；ArkClash 不能继续占用它作为内部通道。完整手机功能还需要配置构建、脚本、请求/DNS记录、探测、备份等不属于 mihomo REST 的方法。

阶段 0 实机验证了 Go 在 filesDir 监听 Unix socket、UI 经 ArkTS LocalSocket 连接的跨进程往返（单次 17 ms）。这只证明通路，不证明生产协议的容量、安全性和恢复已经完成。

## 决定

Go 在 `filesDir/ipc/core.sock` 提供单连接复用的 NDJSON 协议，先建立通道再准备配置。字段 camelCase，方法名为 `area.verb`，例如 `proxy.select`。内核只在 VPN 进程运行。

- UTF-8 按字节切换行后解码，避免多字节字符跨分片损坏。
- hello 交换主/次协议版本、bootId、能力和快照。私有目录/文件权限限制加每次启动的随机令牌；令牌不进日志或备份。残留 socket 只在持宿主锁且确认旧实例已死后删除。
- 请求 id 用于响应匹配；mutation 另带 operationId 和期望 revision。超时表示未收到答复，不能推断操作没执行；通过 operation.get / 快照对账再决定是否重试。
- 大响应走受控 blobId，不接受任意路径；普通帧、未完成请求、事件和总队列字节数都有限额。响应队列阻塞最多 5 秒，满后断开客户端，不能阻塞转发线程。
- 按主题订阅。快照与后续事件在同一序列化点衔接，每主题 seq、bootId 和丢弃计数可检测缺口。断线即退订；重连按新快照恢复。UI 隐藏停止展示用采集。
- 协议主版本不匹配只允许协调器执行一次受控重启，失败提示，不无限重试。

完整 envelope、上限、错误码、取消和幂等规则在架构 Issue 与通道实现工单中定义，并用双方共享的 JSON 夹具验证；不得留给每个页面自行实现。

需要系统能力的动作通过已有 NAPI 线程安全函数转给 ArkTS 宿主；调用有 deadline、bootId 和 generation，宿主销毁释放所有等待。Go 不能持运行态锁等待宿主再回调 Go。下载并非技术上只能由 ArkTS 完成：共享配置业务留在 ArkTS，经内核拨号的网络部分留在 Go。

外部 controller 默认关闭，用户开启时使用自己的地址与 secret；内部令牌绝不进入最终配置。现有 embed 模式限制绕过管线的写操作，在设置兼容工单列出支持和拒绝的端点；未解决前不声称完整外部 API 等价。

旧 runtime.json、core_error.txt 在新握手、失败状态、版本迁移均验证后删除，不在协议切换前先删恢复路径。

## 后果

- 配置加载和代理停止期间，通道仍可报告精确状态。
- UI 不依赖 mihomo REST 结构；协议变化集中在 Go RPC 与 client/api 两处。
- 主动探测使用 Go 出站拨号器，不依赖 mixed 端口是否开启。
- 通道切换与对应 UI 在同一个 HAP 版本交付；旧 HTTP 适配只作迁移，不保持两套状态真源。
