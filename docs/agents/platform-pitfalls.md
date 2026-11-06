# 平台陷阱

这些坑都是在真机（Pura 70 Ultra，API 26）上踩过并修好的。每一条都写了：日志里长什么样、原因、补丁在哪、升级依赖时怎么复查。

## 1. 内核加载失败：initial-exec TLS

- **现象**：`Error relocating .../libclash.so: initial-exec TLS resolves to dynamic definition`，ArkTS 里 `core` 是 `undefined`。
- **原因**：Go 在 linux/arm64 上把当前 g 指针放在 initial-exec TLS 里，鸿蒙的 musl 不允许 dlopen 加载的库这么用。官方还没修（golang/go#54805）。
- **补丁**：`scripts/go-ohos.patch`，由 `build-core.sh` 打进 `.toolchain/` 里的 Go 副本，一共三处：
  - g 改存在 C 定义的线程局部变量里，通过 TLSDESC 访问（`runtime/cgo/gcc_tls_linux_arm64.S`），`load_g`/`save_g` 调用这段汇编。
  - musl 调用 `DT_INIT_ARRAY` 时不传 argc/argv，库入口改用空参数表，auxv 从 `/proc/self/auxv` 读取。因此内核里的环境变量都是空的，配置只能通过 start 的 JSON 参数传进去。
- **试过但不可行**：把 g 放在线程指针后面的固定槽位（Android 的做法）。在 ffrt 等系统线程上 TP+8 已经是 -1，不是空槽位。
- **写汇编时注意**：共享库模式下，Go 汇编读全局变量（`MOVD sym(SB), Rx`）会借用 R27 中转。R27 里存着东西时，先取地址再读：`MOVD $sym(SB), R0; MOVD (R0), R0`。
- **复查**：升级 Go 时补丁必须能打上（打不上脚本会失败）；`llvm-readelf -r libclash.so` 里只能有 `R_AARCH64_TLSDESC`，不能有 `TLS_TPREL`；真机上内核能启动。Go 官方支持 general-dynamic TLS 之后删掉这个补丁。

## 2. 内核自己的流量绕回 VPN

- **现象**：内核的 DNS 查询超时、下载 Geo 数据失败，看上去像没网。
- **原因**：`VpnConnection.protectProcessNet()` 只对经过 libc 创建的 socket 生效，Go 直接发系统调用，绕过了 libc。
- **做法**：`VpnConfig.blockedApplications` 填本应用的包名，按 UID 在内核路由层面整个排除。副作用是 App 自己的流量（比如下载订阅）走直连。
- **复查**：改 VpnConfig 后，确认内核日志里没有 DNS 超时，直连和代理都能连上。

## 3. TUN 启动失败：fstat 被拒

- **现象**：`unix.Fstat(33,...) failed: permission denied`。
- **原因**：gVisor 的 `fdbased.New` 对 fd 做 fstat，只是为了判断它是不是 socket；SELinux 不允许应用读系统给的 TUN 设备属性。
- **补丁**：`scripts/gvisor-fdbased.patch`，被拒绝时按"不是 socket"处理。`build-core.sh` 把 gVisor 模块复制到 `.toolchain/patched/`，打补丁后通过临时 go.mod（`-modfile`）replace 过去，`core/go.mod` 保持原样。（Go 的 `-overlay` 不能替换模块缓存里的文件。）
- **复查**：mihomo 升级带来新的 gVisor 版本时补丁要能打上，真机上 TUN 能启动。

## 4. netlink 被禁用

- **现象**：UDP 直连报 `route ip+net: netlinkrib: permission denied`。
- **原因**：任何需要列网卡的功能都要用 netlink。这里是 mihomo 的回环检测在检查 UDP 目标是不是本机 IP。
- **做法**：`core/loopback.go` 通过 `go:linkname` 关闭回环检测（Clash Meta for Android 也是关掉的）。因为第 2 条已经把本应用排除在 VPN 外，不会形成回环。
- **影响**：`auto-route`、`auto-detect-interface`、按网卡绑定出站这类依赖网卡列表的功能都用不了，`core/tun.go` 里保持关闭。
- **预期内的警告**：`[TUN] get tun name failed for fd`（ioctl 被拒），无害。

## 5. 其他约束

- `VpnConfig.mtu` 的范围是 576–1500。TUN 地址在 `ClashVpnAbility.ets` 和 `core/tun.go` 两处，要一起改。
- 内核重启后，其他 App 还缓存着上一轮的 fake-ip，会出现 `fake DNS record ... missing`，等它们的 DNS 缓存过期就好了。要根治，得打开 fake-ip 持久化（还没做）。
