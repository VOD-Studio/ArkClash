# ADR-0016：诊断记录只在对应工具页可见时采集

## 状态

已采纳。宿主连接、DNS、WebSocket 与 race 回归通过；签名应用、ARM64 真机代理转发及四项产品性能仍是独立验收门禁。

## 背景

FlClash v0.9.3（`be84736605527034689c95bf27828ff27d912c5e`）将连接合并为 Recent/Live 两种 feed。标准 mihomo `/connections` 是活动快照，不能捕获亚秒请求；标准 `/dns/query` 是主动查询，不是被动记录。通用事件通道允许丢事件，Geo 通道只保留最新状态，都不能承担有界诊断历史。

## 决定

- UI 仍不加载内核。沿用已认证 controller、端口、NAPI、TUN 与逐 socket 物理网络绑定；不开放新端口，不更换 mihomo fork 或依赖版本。
- `scripts/mihomo-observation.patch` 最小移植固定 fork `024245dc72bc92f48237f865119afe0cd53ac9e6` 的观察与清缓存能力。连接使用 Join-before-Store 的 Open 和底层 Close 完成后的通知；逐字节路径不添加锁或回调。DNS 使用原子 observer、独立的 4096 项 upstream 归属缓存与五类 initiator（app/rule/direct/proxy/other），不是具体应用身份。隐藏时分类不分配 context；旧 trace 不进入新 observer。Hosts/FakeIP 直接回答不造事件，singleflight 可合并请求。
- `/arkclash/diagnostics/connections` 和 `/arkclash/diagnostics/dns` 是两个独立可见订阅。首个同类订阅安装 hook，最后一个离开卸载；多个订阅共用该类 collector 和采样器。Close 控制帧、EOF、请求取消、写失败、配置退休均解除订阅。隐藏不补采、不回放历史，也不取消正常代理 DNS。打开详情或切 Recent/Live 不改变连接订阅。
- 记录仅驻留内存：连接 canonical 保存全部 live 和最近 2000 次建立，DNS 保存最近 3000 条。初次连接 snapshot 只有 live 基线，不把既有连接补记为 recent；DNS 初始为空。session 的历史边界独立，晚加入者不读取其他订阅的历史。UI 同 boot/config 可保留自己已观察过的旧 session 历史，暂停跟随只保留有界视图（连接 4000、DNS 6000），不是暂停采集。
- 公共帧携带 `type/kind/bootId/configRevision/sessionId/seq/sampledAt/dropped/evicted`。首帧 seq=1，逐帧递增；集合为空也编码为 `[]`。连接 snapshot/reset 包含 live/recent，delta 包含 opened/traffic/closed，按此顺序应用；DNS 对应 records/added。每会话队列 256，先更新 canonical，再在溢出时合并为 reset；reset 恢复最终状态，不丢关闭终态。`dropped` 是合并或跳过的中间事件数，`evicted` 是容量淘汰数，不把 reset 补齐的数据称为丢失请求。
- 除首帧外最多每秒一个数据帧；存在 live 时发送空 delta 推进时长并使速率归零。仅有 live/收尾 tracker 时运行共享秒级采样；DNS 仅在待发事件到来后安排一次延迟 flush。Close 后只对仍在 recent 的 tracker 继续观察累计量，连续两次采样不变即释放。数据表示最后观察到的累计量，不承诺并发 I/O 的最后一字节、精确关闭时间或完整审计。
- writer 在锁内取得不可变 DTO，锁外编码。文本与控制回复共享整帧写锁和 5 秒写 deadline；按 RFC6455 处理 Close/Ping/Pong，数据帧视为协议错误。控制载荷先读入至多 125 字节缓冲，半帧不能长期占住写锁。
- 流与动作携带 `expectedBootId/expectedConfigRevision`。关闭单条/全部使用 `POST /diagnostics/connections/close`，清缓存使用 `POST /diagnostics/dns/clear-cache`；校验和副作用在同一核心 mu 事务内。单条缺 ID 不能退化为全部关闭，不存在的 ID 幂等成功。旧代次返回 409，未就绪 503，非法请求 400；错误码不带 secret、节点或目标 URL。
- 成功 reload 在 parse 成功后、ApplyConfig 前退休会话；parse 失败保留旧会话。beginRuntime 和 stop 同样退休。先撤 hook、标 closed、取消 timer、关连接，释放核心 mu 后才 join worker；hook 不反取核心 mu。DNS 撤钩等待旧回调，因此撤钩不能持有回调需要的 collector/session 锁。
- `dns.ClearAll` 遍历 default/system/proxy/direct、嵌套 defaultResolver 和策略 client，清网络缓存、解包去重重置连接及 system 刷新时间；不清 FakeIP，不删除诊断记录，不承诺并发查询不能再次填充缓存。

## 后果

仅可见采集降低隐藏时的额外工作量，但断线、后台和隐藏期间记录不可恢复。计数提示用于说明真实间断/合并/淘汰，不提供审计保证。继续强制 FindProcessOff，界面没有进程图标、App 筛选或 App 分组。

观察补丁由 `prepare-mihomo.sh` 统一用于宿主和两种 ABI。升级 mihomo 时必须复查调用时点、取消上下文、observer 身份、cache/client 遍历以及同一版本解析下的依赖包回归；宿主和构建结果不能替代真机 UI、转发、耗电、延迟与稳定性测量。
