# 平台陷阱

ARM64 的运行问题已在真机（Pura 70 Ultra，API 26）上验证；x86_64 的动态加载补丁另在 API 26 模拟器做原生冒烟，不代表完成应用/VPN 验收。每一条都写了现象、原因、补丁位置和升级复查方法。

## 1. 内核加载失败：initial-exec TLS

- **现象**：`Error relocating .../libclash.so: initial-exec TLS resolves to dynamic definition`，ArkTS 里 `core` 是 `undefined`。
- **原因**：Go 在 linux/arm64 上把当前 g 指针放在 initial-exec TLS 里，鸿蒙的 musl 不允许 dlopen 加载的库这么用。官方还没修（golang/go#54805）。
- **补丁**：`scripts/core/patches/go/ohos-arm64.patch`，由 `scripts/core/build.sh` 打进 `.toolchain/` 里的 Go 副本，关键改动包括：
  - g 改存在 C 定义的线程局部变量里，通过 TLSDESC 访问（`runtime/cgo/gcc_tls_linux_arm64.S`），`load_g`/`save_g` 调用这段汇编。
  - musl 调用 `DT_INIT_ARRAY` 时不传 argc/argv，库入口改用空参数表，auxv 从 `/proc/self/auxv` 读取。因此内核里的环境变量都是空的，配置只能通过 start 的 JSON 参数传进去。
- **试过但不可行**：把 g 放在线程指针后面的固定槽位（Android 的做法）。在 ffrt 等系统线程上 TP+8 已经是 -1，不是空槽位。
- **写汇编时注意**：共享库模式下，Go 汇编读全局变量（`MOVD sym(SB), Rx`）会借用 R27 中转。R27 里存着东西时，先取地址再读：`MOVD $sym(SB), R0; MOVD (R0), R0`。
- **复查**：升级 Go 时补丁必须能打上（打不上脚本会失败）；`llvm-readelf -r libclash.so` 里只能有 `R_AARCH64_TLSDESC`，不能有 `TLS_TPREL`；真机上内核能启动。Go 官方支持 general-dynamic TLS 之后删掉这个补丁。

### x86_64 模拟器

- `scripts/core/patches/go/ohos-amd64.patch` 修改 linux/amd64 共享模式的 TLS 指令展开，由原生辅助函数通过 TLSDESC 返回线程局部 `g` 的偏移。辅助函数必须保留非目标寄存器与标志位；解析和后续 TLS 读写不能被异步抢占。初始化同样使用空参数表。
- `make core ABI=x86_64` 会重建该私有工具链的 `asm`、`compile`、`link`，只复制源码而沿用旧编译器不生效。产物不能出现 `R_X86_64_TPOFF*` 或 `R_X86_64_GOTTPOFF`。
- `make core-smoke ABI=x86_64` 在已连接模拟器上验证动态加载前已有线程、加载后新线程及 C→Go→C 调用，完成后清理临时文件。不使用 `LD_PRELOAD`，不卸载 Go 共享库。
- Go 升级后两种架构都要重新构建、检查 TLS 和运行冒烟；x86 额外复查编译器生成的辅助调用。详细决定见 [ADR-0014](../adr/0014-x86-emulator-toolchain.md)。

### Go 1.27.4 升级复查（2026-11-16）

- ARM64 与 x86_64 原有补丁无需修改；两种架构均通过 `make core`（含禁止静态 TLS 重定位检查）和 `make hap`。`make test TESTS=core` 通过；`make lint` 无错误，缺少 shellcheck、actionlint，相关检查跳过。
- API 26 x86_64 模拟器通过 `make core-smoke ABI=x86_64`：加载前 4 线程、加载后 16 线程，42,002 次 API 调用，耗时 55.871 ms。该数字仅为原生冒烟耗时，不代表启动或网络性能。
- `make run ABI=x86_64` 因未配置签名而未能安装。ARM64 真机启动、TUN 与代理转发尚未验证；冷启动、8 小时待机耗电、新连接延迟及 24 小时稳定性均无本轮测量值，需签名后在同一真机、同一配置下与升级前版本及同类客户端对比。

## 2. 内核自己的流量绕回 VPN

- **现象**：DNS 查询超时、连接不断增加，VPN 进程内存迅速超过 1 GiB。一次真机快照里有 20,284 条指向默认 DoT 上游 853 端口的 TUN 连接、40,695 个 goroutine；GC 仍在运行。
- **原因**：`VpnConnection.protectProcessNet()` 和 `blockedApplications` 不足以保护 Go 直接通过系统调用创建的 socket。内核的 DIRECT 出站再次进入 TUN，gVisor 接受握手后又建立一条 DIRECT 出站，形成递归。
- **做法**：`core/internal/platform/socket.go`（`//go:build ohos`）在初始化时设置 mihomo 的 `dialer.DefaultSocketHook`，在 TCP connect / UDP send 前，通过 `OH_NetConn_GetDefaultNet` 和 `OH_NetConn_BindSocket` 把 socket 绑定当前默认物理网络。查询或绑定失败就返回错误，不放行未保护的 socket。每次获取当前网络，不缓存会在 Wi-Fi/蜂窝切换后失效的 netId。构建 `libclash.so` 时必须传 `-tags with_gvisor,ohos`；缺 `ohos` 标签会因 `core/cmd/clash/lib.go` 被排除而触发 fail-closed 编译失败（[ADR-0040](../adr/0040-core-build-tags-and-host-tests.md)、[ADR-0044](../adr/0044-core-cmd-and-five-layer-internal-dag.md)）。
- **界面进程**：继续保留 `protectProcessNet()` 和本应用的 `blockedApplications`，供 ArkTS/libc 流量直连；它们不能替代 Go 的逐 socket 保护。决定见 [ADR-0008](../adr/0008-bind-core-sockets-to-physical-network.md)。
- **复查**：同一进程持续连接并通过浏览器访问代理站点；观察 RSS、活动连接和 TUN/853 连接是否持续增长，不能只以一次网页能打开为准。受控实验中仅开启 socket 绑定，goroutine 在约 15 秒内从 40,695 降到 73，未使用定时 GC 或内存上限。

## 3. TUN 启动失败：fstat 被拒

- **现象**：`unix.Fstat(33,...) failed: permission denied`。
- **原因**：gVisor 的 `fdbased.New` 对 fd 做 fstat，只是为了判断它是不是 socket；SELinux 不允许应用读系统给的 TUN 设备属性。
- **补丁**：`scripts/core/patches/gvisor/fdbased.patch`，被拒绝时按"不是 socket"处理。`scripts/core/prepare-deps.sh` 把 gVisor、mihomo、tailscale 模块复制到临时或 `.toolchain/` 目录，按 `scripts/core/patches/<模块>/series` 的顺序打补丁（目录里有补丁没登记进 `series` 时直接报错），再通过临时 go.mod（`-modfile`）replace 过去，供构建、vet、govulncheck、CodeQL 与宿主回归共用，`core/go.mod` 保持原样。（Go 的 `-overlay` 不能替换模块缓存里的文件。）
- **复查**：mihomo 升级带来新的 gVisor 版本时补丁要能打上，真机上 TUN 能启动。

## 4. netlink 被禁用

- **现象**：UDP 直连报 `route ip+net: netlinkrib: permission denied`。
- **原因**：任何需要列网卡的功能都要用 netlink。这里是 mihomo 的回环检测在检查 UDP 目标是不是本机 IP。
- **做法**：`core/internal/platform/loopback.go` 通过 `go:linkname` 关闭回环检测（Clash Meta for Android 也是关掉的）。出站绕过 VPN 依赖第 2 条的逐 socket 物理网络绑定，不能只依赖应用排除名单。
- **影响**：`auto-route`、`auto-detect-interface`、按网卡绑定出站这类依赖网卡列表的功能都用不了，`core/internal/engine/tun.go` 里保持关闭。
- **预期内的警告**：`[TUN] get tun name failed for fd`（ioctl 被拒），无害。

升级 Tailscale 后复查 `scripts/core/patches/tailscale/netmon.patch`。首次使用出站时应读取 Network Kit 的物理网络快照，并从系统回调接收切网事件。真机验收需要实际拨号和 DNS 查询，单独保存节点不会启动 tsnet。[ADR-0035](../adr/0035-tailscale-network-monitor.md)

## 5. 其他约束

- MTU 范围为 576–1500，启用 IPv6 时为 1280–1500。TUN 地址在 `shared/VpnNetwork.ets` 和 `core/internal/engine/tun.go` 中定义，两处需同步。[ADR-0020](../adr/0020-vpn-network-settings.md)
- 内核重启后，其他 App 还缓存着上一轮的 fake-ip，会出现 `fake DNS record ... missing`，等它们的 DNS 缓存过期就好了。要根治，得打开 fake-ip 持久化（还没做）。

## 6. 内嵌请求的取消、DNS 池与自动选路

- `inner.HandleTcp` 会在内部另建后台拨号上下文，关闭本地 pipe 不能证明实际拨号已经停止。内嵌请求要把取消传入规则解析、DNS 和出站拨号，并等待自己创建的工作结束后再释放执行名额。
- `scripts/core/patches/mihomo/rule-dial.patch` 提供该调用链；`scripts/core/patches/mihomo/urltest-cancel.patch` 使用户取消不写入节点失败健康或测速历史，真实失败和超时保持原语义。`scripts/core/prepare-deps.sh` 为手机构建、宿主回归与 vet 准备同一份模块副本，不改 Go 模块缓存或 `core/go.mod`。
- DoH/H2/H3 和 DoQ 会缓存连接。单次请求若拥有连接关闭权，就必须使用自己的 transport、连接与 TokenStore；不能把普通 DNS 正在共享的连接登记到单次请求的清理列表。
- 自动组的通知回调只做有界原子标记和入队，不取得核心锁、不重入组方法。不能用通用异步分发器冒充同步标记，也不能在每个健康结果完成时重置 URLTest 原有缓存、提前改变真实选择。
- provider 的后台 Fetcher 不能强引用带 finalizer 的包装器，否则热切换后旧下载、健康检查和文件监听无法回收。更新通知使用弱引用，配置退休后同时解除本应用的订阅与定时任务。
- 升级 mihomo 后先确认两个补丁能应用并通过 `make core`，再复查真实拨号取消、普通 DNS 与探测并发、provider 退休、缓存到期选路及同名成员身份。真机转发与长时间待机仍按独立门禁验证。
- `CORE_RACE=1 make test TESTS=core` 揭示 File provider 文件监听与手动更新并发读取/写入 Fetcher hash 的竞态。`scripts/core/patches/mihomo/provider-hash.patch` 在已有 loadBufMutex 下取得 hash 快照，网络读取仍在锁外；不改变更新与通知语义。
- `scripts/core/patches/mihomo/provider-manage.patch` 为运行中 Provider 管理与节点入库补充三组最小钩子：在 `adapter.ParseProxy` 保存节点原始配置深拷贝（`ArkClashRawDefinition`，直接节点与 provider 成员统一经过该入口），为 `ProxySetProvider` / `RuleSetProvider` 暴露返回变化标记的 `ArkClashUpdate`、`ArkClashReplace`、`ArkClashFormat` 与无锁原子时间戳 `ArkClashUpdatedAt`，并将 `rules/provider.baseProvider.strategy` 改为原子指针以避免替换与并发规则匹配产生数据竞态。升级 mihomo 后需确认该补丁可干净应用并通过 `CORE_RACE=1` 宿主测试。
- `scripts/core/patches/mihomo/provider-reuse.patch` 让热切换复用定义未变、已加载的 Domain/IPCIDR rule-provider：`config.parseRuleProviders` 新建前经 `ArkClashSetRuleProviderReuse` 登记的判断询问内核，`executor.loadProvider` 经 `ArkClashSetProviderLoaded` 登记的判断跳过复用实例的 `Initial`。替换必须发生在解析阶段，DNS 策略、fake-ip 过滤和嗅探此时就拿走了 provider 引用。升级 mihomo 后确认这两处仍是 rule-provider 的唯一构造和初始化入口、`RULE-SET` 仍按名字从 tunnel 取 provider，并跑 `TestRuleProviderReuseAcrossReload`（[ADR-0043](../adr/0043-reuse-unchanged-rule-providers.md)）。

## 7. 系统与 Go 不能共同关闭同一个 TUN fd

- OpenHarmony `NetworkVpnClient::DestroyVpn()` 会关闭 create 返回的原始 fd。Go 必须在真正获取 TUN 接口时复制，不能把原件直接交给 `os.NewFile`。
- `scripts/core/patches/mihomo/tun-fd.patch` 给 Linux `sing_tun.tunNew` 加 `F_DUPFD_CLOEXEC`；平台只关闭原件，Go listener 只关闭副本。固定版本的外部 fd 分支直接包装文件，没有包装后返回错误的路径。
- stack 在 Start 前登记到 listener，构造失败走已有 Close 回滚。不能在 `sing_tun.New` 外层出错后再盲目 close；Close 出错后保留不确定性，不能重试关闭可能已被复用的 fd。
- `CORE_LINUX_FD=1 make test TESTS=core` 在 macOS 上交叉编译后用本机 Docker（默认 `alpine:latest`，可设 `CORE_LINUX_IMAGE`）验证原 fd、副本、构造回滚与复用；Linux 主机直接执行。未配置此项的 macOS 回归会明确跳过 Linux fd 用例。
- 升级 mihomo/sing-tun 后复查外部 fd 分支、stack 启动回滚及一次性关闭；Linux 容器通过不能替代手机 TUN 成功转发和至少 20 轮连断的 fd/线程验收。无 TUN 预热和驻留边界见 [ADR-0017](../adr/0017-core-ready-without-vpn.md)。

