# 0043 热切换复用定义未变的 rule provider

- 状态：已采纳，待真机验收。补充 [0010](0010-hot-switch-reload-in-vpn.md) 的应用阶段。

## 背景

[0010](0010-hot-switch-reload-in-vpn.md) 的热切换每次都重新解析整份配置并调用 `executor.ApplyConfig`。mihomo 在解析时为每个 rule-provider 新建实例，应用时逐个 `Initial`：重新读本地文件、重新解析每一条规则。应用阶段 tunnel 挂起，新的 TCP 连接直接关闭，UDP 被丢弃。0010 记录这个窗口在 provider 文件都在本地时约 20ms，那是小规则集下的数字。

保存附加规则、DNS 覆写、常规设置和配置脚本，以及切换配置，都走同一条热切换路径。真机用一份带 21 个 rule-provider 的订阅，在临时计时版本里测得保存一条附加规则的内核耗时 3.9–4.9 s：读取和解析 YAML 30–80 ms，其余更新约 0 ms，加载 rule-provider 3.8–4.8 s。provider 并发加载，总耗时等于最大的那个：20.4 万条的域名规则集 4.4–4.8 s，11 万条的 2.0–2.2 s，其余 19 个都在 0.6 s 以内。界面因此转圈数秒，期间所有新连接失败。

规则集定义没有变，内容也由 provider 自己的定时更新或文件监听维护，每次热切换重新解析是纯粹的重复劳动。

## 决定

- `scripts/mihomo-provider-reuse.patch` 给 mihomo 加两个钩子：
  - `config.ArkClashSetRuleProviderReuse` 登记的判断：`parseRuleProviders` 新建实例前先询问；返回运行中的实例时直接放进 provider 表。规则、DNS `nameserver-policy`、fake-ip 过滤和嗅探都在之后按这张表取 provider，所有引用一致指向同一个实例。只在这里替换，不在 `ApplyConfig` 里换：那时 DNS 等已经引用了新建的空实例。
  - `executor.ArkClashSetProviderLoaded` 登记的判断：`loadProvider` 跳过已完成 `Initial` 的复用实例。再次 `Initial` 会重新解析，还会重复启动定时更新或文件监听。
- `core/rule_provider_reuse.go` 实现判断：
  - `prepareRawConfig` 在 `ParseRawConfig` 之前，对每个 rule-provider 定义（叠加覆写和规则集库之后）的 JSON 编码取 SHA-256 指纹，随 `inboundSettings` 传到应用阶段。
  - 钩子在每次启动内核时以原子方式登记，不用 `init()`（[0040](0040-core-build-tags-and-host-tests.md) 的白名单只留给路由注册和平台钩子）。
  - 启动和每次热切换（`ReloadTx.CommitReload`）在 `executor.ApplyConfig` 之后发布这一代的指纹和实际生效的实例；内核停止及下一次启动前清空，不跨内核代次复用。这一代存在 `coreEngine.ruleProviders`（[0042](0042-core-engine-and-reload-tx.md) 不允许新增根包全局变量），在核心锁下整份替换，钩子在锁外原子读取。
  - 同时满足以下条件才复用：同名、指纹相同、运行中的实例是 `RuleSetProvider`、behavior 为 Domain 或 IPCIDR、来源为 HTTP 或 File、已加载出内容（`Count() > 0`）。Classical 的每一行经 `ParseRule` 解析，可能用到 Geo 数据等两份配置间会变的状态；Inline 的内容在配置里，重新解析很便宜；上次加载失败的实例让新配置照常重试。
- proxy-provider 不复用：实测加载只需数毫秒，节点对象本来就随配置重建。
- `core/prefetch.go` 自己调用 `RP.ParseRuleProvider`，不经过钩子，不会拿到并关闭运行中的实例。

## 后果

- 定义相同意味着地址、路径、更新间隔、代理和请求头都相同，复用实例继续负责下载和文件监听，内容更新的时机与改动前一致。规则集库的文件路径包含内容版本（[0025](0025-managed-rule-sets.md)），同步出新版本时定义随之变化，按新建处理。
- 预览、校验这类不应用的解析也会拿到运行中的实例，它们只读不初始化，丢弃配置不影响实例。钩子在核心锁外可能并发调用，只读原子发布的那一代。
- 宿主回归 `TestRuleProviderReuseAcrossReload` 覆盖复用、Classical 重建、加载失败后重试、定义变化后新建以及停止后清空。
- 升级 mihomo 后确认：补丁能干净应用；`parseRuleProviders` 仍是配置里 rule-provider 的唯一构造入口；`loadProvider` 仍是热切换里唯一调用 `Initial` 的地方；`RULE-SET` 仍在匹配时按名字从 tunnel 取 provider。
