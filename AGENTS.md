# ArkClash

原生 HarmonyOS NEXT 代理客户端：ArkTS/ArkUI 界面，mihomo 内核（Go，交叉编译成 `libclash.so`）。交互参考 FlClash，许可证 GPL-3.0。

## 产品底线

项目存在的理由是比同类客户端快、省电、稳。四个指标在同一台真机上和同类客户端对比：冷启动到可操作 < 500ms、开着代理待机 8 小时的耗电、新连接建立延迟、24 小时内核不重启。改动会影响这些指标时，交付里附上测量方法和数字。

- UI 进程只做界面：不加载 `libclash.so`，先用缓存状态渲染，内核状态异步获取。
- 数据靠推送：流量、连接、日志走内核的 WebSocket，页面不可见就退订。轮询只用于有上限的一次性就绪检测。
- ArkTS 主线程只做轻活：文件、网络、内核调用都走异步（Promise / NAPI async work）。

## 进程与代码边界

| 位置 | 职责 |
|---|---|
| `entry/src/main/ets/pages/`、`features/`、`client/` | UI 进程（EntryAbility），通过 `client/CoreClient` 控制内核 |
| `entry/src/main/ets/vpn/` | VPN 进程（ClashVpnAbility），持有 TUN 和内核；VPN 开着时系统保活这个进程 |
| `entry/src/main/cpp/` | NAPI 桥，start/stop 在工作线程执行 |
| `core/` | Go 封装层，C API 在 `core/arkclash.h`，和 `lib.go` 一起改 |

两个进程只走两条通道：mihomo external-controller（`127.0.0.1:19090` + secret），以及 `filesDir` 下的文件（见 `shared/Runtime.ets`）。ArkClash 接管的配置项（TUN、controller、进程查找、DNS 开关）统一在 `core/lib.go` 的 `applyOverrides` 里强制，订阅里写什么都会被覆盖。

## 构建

- 内核只用 `scripts/build-core.sh` 构建。它会准备打过补丁的 Go 工具链和依赖（放在 `.toolchain/`），交叉编译，并检查产物里没有 initial-exec TLS 重定位。
- Geo 数据用 `scripts/fetch-geodata.sh` 下载到 `rawfile/geo/`，随 HAP 打包。
- HAP：`hvigorw assembleHap --mode module -p product=default -p buildMode=debug`，`DEVECO_SDK_HOME` 指向 DevEco Studio 的 `Contents/sdk`。
- `build-profile.json5` 的 SDK 版本号：API 26 起写 `"26.0.0"`，更早的写 `"6.0.2(22)"` 这种带括号的格式。

## 真机验证

动到内核、NAPI 或 VPN 的改动，以真机跑通为完成标准：装机、连接、用浏览器打开一个被墙的站点，并在内核日志里看到这条连接命中了代理节点。

- 装机：`hdc install -r entry/build/default/outputs/default/entry-default-signed.hap`，启动：`hdc shell aa start -a EntryAbility -b com.vodstudio.arkclash`。
- 日志：`hdc hilog | grep -E "ArkClashCore|ClashVpnAbility"`，应用的 hilog domain 是 `0x0A11`。
- 崩溃日志只按文件名精确拉取 ArkClash 自己的（`/data/log/faultlog/faultlogger/cppcrash-com.vodstudio.arkclash-*`）。设备上其他应用的日志是用户隐私。
- 符号化：去掉 `-s -w` 另编一份到临时目录，用 `llvm-symbolizer --obj` 解析崩溃地址。

## 平台陷阱

改内核、VPN 或升级 Go / mihomo / gVisor 前，先读 `docs/agents/platform-pitfalls.md`。里面记录了 musl 和 Go 共享库的 TLS 冲突、`protectProcessNet` 管不到 Go 的 socket、SELinux 禁止对 TUN 做 fstat、netlink 被禁用这几个坑，以及各自的补丁和升级时的复查方法。

## 注释

注释用中文。已有的英文注释保持原样，由人工统一改。写注释前读 `docs/agents/comments.md`。

## 安全

- 签名材料只留在本机。DevEco 自动签名会把证书路径和加密后的密码写进 `build-profile.json5` 的 `signingConfigs`，这部分改动一直不暂存；提交时按文件路径精确暂存。
- 订阅链接、controller secret、节点信息只放在应用沙箱里，不进日志、提交、issue 或 PR。

## 分支与提交

开分支、提交、改历史、开 PR 或 issue 前读 `docs/agents/git.md`。要点：新任务从 `main` 拉分支；中文 Conventional Commits；一个 commit 一个逻辑变更；只在本地提交，等用户要求再推送。

## 界面

写或改 ArkUI 页面、组件前读 `docs/agents/ui.md`。
