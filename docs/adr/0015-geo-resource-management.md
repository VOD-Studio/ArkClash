# 0015 Geo 资源由 UI 设置与内核任务分别管理

- 状态：已采纳；ARM64 真机与性能验收独立记录。
- 跟踪：[#71](https://github.com/VOD-Studio/ArkClash/issues/71)、[#86](https://github.com/VOD-Studio/ArkClash/issues/86)

## 背景

内置版本升级原先直接覆盖两个活动文件，不能保留用户在线更新。上游 updater 关闭旧 mmap 后再写目标，自动 ticker 也不可停止，不适合作为内嵌 VPN 的安全资源管理器。

## 决定

只管理 MMDB、ASN、GEOIP、GEOSITE，不扩展规则集、图标或脚本。离线可查看本地文件和编辑设置；资源页及自动任务只由已经就绪的 VPN 内核下载。保留 mihomo 配置解析时初始化必需文件的既有行为。

UI 是 `geo-settings.json` 的唯一写入方，串行原子保存，revision 冲突保留草稿；启动等待已经提交的保存。Go 只读取设置，强制覆盖订阅中的 Geo URL 和更新选项，关闭上游不可停止的自动更新器。保存成功与内核应用成功是两个状态，不把“待应用”当作已生效。

Go 是在线数据库和 `geo-<id>.json` 元数据的唯一写入方。四项固定路径，不接收任意目标路径。下载串行、按当前规则拨号、真实传递取消，无直连降级；限时、限额并脱敏错误。候选在同目录独立临时文件完成格式验证，提交与设置应用、reload、start、stop 共用核心锁边界。文件替换和 reader/cache 切换不重建 TUN、不改变配置代次或节点选择。

MMDB/ASN reader 使用原子指针发布，初始化与替换只在慢路径加锁。已发出的旧 reader 不手动 Close，由固定 `maxminddb-golang v1.12.0` 的 Open finalizer 在最后引用释放后回收。候选未提交时必须 Close；升级依赖须复查此所有权前提。生产不主动 GC，查找不增加每次分配、引用计数或全局读锁。

自动更新默认关闭、24 小时，启用后只有一个可停止的一次性 timer，首次到期至少推迟 10 秒。按文件修改时间和持久化 lastAttemptAt 的较大值计时，失败和相同内容同样等待完整间隔。关闭仅取消自动任务，停止内核取消全部任务并在释放核心锁后等待真实拨号收尾。

资源页面使用独立 `/arkclash/geo/events` 最新值快照流：订阅原子登记并发送初始状态，每连接容量一，积压时以新快照替换旧快照，确保最终 busy 状态不会被丢弃。UI 按 boot/revision 合并，仅可见时订阅；隐藏清掉本页批次提醒，不取消内核下载，也不回放旧 Toast。不新增网络轮询。

保留现有两份内置资源，不为四行列表增加 HAP 资产。安装包升级仅替换未接管文件；已 managed 或元数据损坏的现有文件保守保护，缺失的内置文件仍恢复。复制采用异步临时写、长度确认、关闭后 rename，全部完成才更新 bundle stamp，不对活动数据库 TRUNC，不在启动扫描大文件 hash。

## 后果

新增一份跨进程设置和四份小元数据；保留原有两个打包资产及 C ABI。独立快照流和明确写入所有权增加少量控制代码，换取无后台轮询、可取消调度和失败时保留旧数据库。reader 补丁依赖固定 maxminddb finalizer 契约，升级必须复查。

## 验证边界

宿主用例执行产品实现，固定 MMDB 夹具仅用于测试、不打入 HAP。覆盖 reader 并发存活、格式验证、失败保留原文件、取消、调度、设置冲突与 UI 状态恢复。宿主 race 和 ARM64 构建不能替代设备转发。

数据层已执行 `make test TESTS="resources runtime core" CORE_RACE=1`；修正 MMDB 测试候选生成和重复 ID 夹具后，`make test TESTS=core CORE_RACE=1` 全部通过。`make lint CHECKS=go`（gofmt、go vet）与 `make core ABI=arm64-v8a && make hap ABI=arm64-v8a` 通过，产物未签名；构建保留已有 ArkTS 异常处理警告。

客户端与页面阶段执行 `make test TESTS="resources runtime dashboard"`，64/64 通过，涵盖真实 Controller/ControllerSocket、乱序与极快完成、重连消除 busy、隐藏/boot 换代、旧 Sheet 冲突和待应用 gate。其余 lint 检查通过，ArkTS codelinter 为 0 errors；shellcheck、actionlint 未安装而跳过，zizmor 使用离线模式。修正无障碍描述的 SDK 重载调用后，最终 ARM64 HAP 构建通过：`dist/ArkClash-0.5.1-debug-unsigned.hap`。

同一 ARM64 真机、配置、网络下，分别记录修改前后冷启动 10 次中位数、新连接 20 次中位数、自动更新默认 24h 时开/关各 8h 待机耗电、24h bootId 是否变化。没有测量就不填估计值；设备或签名不可用时保留门禁，不自动签名或以模拟器通过代替。

本轮环境检查：`hdc list targets` 仅有 `127.0.0.1:10026`，客体 ABI 为 `x86_64`；项目没有签名配置。实际执行 `make run ABI=arm64-v8a`，因缺少 `dist/ArkClash-0.5.1-debug-signed.hap` 在安装前退出。ARM64 真机深浅色/交互、VPN 转发与四项性能数字均未测；不以模拟器、宿主或构建结果填充这些数字。
