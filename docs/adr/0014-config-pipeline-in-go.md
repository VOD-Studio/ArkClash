# 0014 配置变换、候选准备和运行态提交分离

- 状态：目标决策，待实施（2026-11-13）
- 实现后替代：[0010](0010-hot-switch-reload-in-vpn.md) 的重载流程；保留不重建系统 TUN、准备失败保持旧配置的原则。

## 背景

完整手机功能要求标准扩展、全局规则、脚本、自定义配置、覆写和最终配置预览。当前 applyOverrides 只有少数强制项。把 `config.ParseRawConfig` 包成名为纯函数的 Build 会掩盖 provider、文件、全局配置和候选资源的副作用；预览不能因此触发下载或更改运行态。

行为依据为 FlClash 固定提交 `be84736605527034689c95bf27828ff27d912c5e` 的 `lib/common/task.dart`、`core/profile_base.go`、`lib/providers/actions/setup.dart`；本项目自行实现，不移植其 Go 封装或 fork。

## 决定

- `Transform(InputSnapshot) → BuiltDocument` 只接收一致 revision 的值输入，完成合并、受限脚本、平台约束、稳定 YAML/hash/计数，不创建运行资源。冷加载、热切换和预览共用。
- `Prepare(BuiltDocument) → Candidate` 进入 mihomo 解析前必须隔离候选参数。原版 ParseRawConfig 的 temporaryUpdateGeneral 会临时改变 mode、IPv6、拨号选项、Geo/UA 并清缓存，运行态互斥锁不能挡住其它 mihomo 读者。实现需新增显式 ParseContext，参数化解析依赖而不覆盖运行全局，必要上游补丁单独提交；Geo准备、数据库和注册对象逐项登记候选资源与 Close 责任。未经并发流量验证，不宣称零影响或完整回滚。
- `Runtime.Commit(Candidate, expectedRevision)` 在串行协调器内提交，核对操作代次，恢复选择后才允许接流量。失败要报告准备失败、部分应用失败和恢复结果的区别。

变换顺序、DNS浅合并与 fallback-filter 二级合并、附加规则顺序、MATCH占位、custom只注入引用节点、未勾选覆写、空值规则、REALITY short-id类型保留，逐项按架构 Issue 固定夹具。脚本后再集中验证平台强制项，脚本不能绕过 TUN、进程查找、沙箱路径和系统时钟限制。

脚本选择独立 QuickJS C 桥，在 VPN 工作线程执行：完整 `main(config)`、const箭头、async/Promise、null/undefined保持原值、10秒中断和256MiB内存限额。没有网络、文件、timer或require。goja 的同等资源合同尚未核实，不能通过省略限额或async作为默认替代。具体版本、交叉编译与ABI在脚本实现工单验证；这是同进程资源约束，不是系统级沙箱。

节点选择按配置恢复，支持 Selector 和 URLTest/Fallback 固定/取消固定。选择有独立 revision，不因为内容 hash 未变就跳过；禁用 mihomo 按组名跨配置恢复。

热切换在 Transform/Prepare失败时保留旧运行配置，沿用 ArkClash 既有行为；这与 FlClash 推空配置不同，PRD显式记差异。`executor.ApplyConfig` 返回void，不等于所有资源可用；实现须报告 provider/监听终态和warnings。

内核内存和文件不是同一事务。保存 prepared journal → Store提交 → 内核提交 → active记录；失败尝试恢复旧配置和指针，CAS冲突或无法恢复时停止转发并显示恢复失败。进程中止后按journal和完整manifest恢复，不假装跨文件/内存天然原子。

## 后果

- 纯变换可以离线对照测试；候选资源、应用和恢复单独集成测试。
- 预览不会偷偷改变当前核心或发健康检查。
- 核心状态同时暴露期望与实际生效配置，界面不会在失败后展示错误的“当前配置”。
- 热切换保持系统 TUN，但 mihomo暂停新连接的窗口仍需测量，不能承诺零丢包。
