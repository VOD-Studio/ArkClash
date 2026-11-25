# ArkClash

原生 HarmonyOS NEXT 代理客户端：ArkTS/ArkUI 界面，mihomo 内核（Go，交叉编译成 `libclash.so`）。交互参考 FlClash，许可证 GPL-3.0。

## 第一次接手

刚 fork 本仓库、或在一台新电脑上第一次搭环境时，按 `docs/agents/fork-setup.md` 一步步完成。改 `.github/`、CI 配置或发版流程前读 `docs/ci.md`。

## 产品底线

项目存在的理由是比同类客户端快、省电、稳。四个指标在同一台真机上和同类客户端对比：冷启动到可操作 < 500ms、开着代理待机 8 小时的耗电、新连接建立延迟、24 小时内核不重启。改动会影响这些指标时，交付里附上测量方法和数字。

- UI 进程只做界面：不加载 `libclash.so`，先用缓存状态渲染，内核状态异步获取。
- 数据靠推送：流量、连接和日志的数据流走内核 WebSocket，页面不可见就退订。连接与 DNS 的应用级采集通道可继续保留有界历史。轮询只用于有上限的一次性就绪检测。
- ArkTS 主线程只做轻活：文件、网络、内核调用都走异步（Promise / NAPI async work）。

## 架构

UI 进程只做界面，内核和 TUN 在 VPN 进程里，两者只通过 mihomo controller 和 `filesDir` 文件通信。新增目录、跨进程改动、调整依赖方向前读 `docs/architecture.md`。做出新的架构取舍时在 `docs/adr/` 写一份决策记录。ArkClash 接管的配置项（TUN、controller、进程查找、DNS 开关、节点选择存储，以及用户在界面上选过的出站模式和局域网代理）统一由 `core/lifecycle.go` 的 `applyOverrides` 强制，热切换后也保持。节点选择用 `profiles/<id>.selected.json`，关闭 mihomo 的全局 `profile.store-selected`，恢复每配置选择后才启用转发。

## 提交

每完成一个功能点，单独创建一次 Git 提交。

## 构建与真机验证

所有本机构建、检查、装机都通过根目录的 `Makefile`，`make help` 列出全部目标。脚本在 `scripts/`，工具路径由 `scripts/env.sh` 统一定位。本机可用 DevEco Studio 或 Command Line Tools，CI 打包使用 Command Line Tools。

- 内核只用 `make core` 构建：它准备打过补丁的 Go 工具链和依赖（`.toolchain/`），交叉编译，并检查产物里没有 initial-exec TLS 重定位。Go 版本固定在 `.go-version`。
- 首次构建先 `make geodata`，把 Geo 数据内置进 HAP。
- 提交前跑 `make lint`，包括 ArkTS 分层规则检查（`scripts/check-arch.py`）。
- `build-profile.json5` 的 SDK 版本号：API 26 起写 `"26.0.0"`，更早的写 `"6.0.2(22)"` 这种带括号的格式。

动到内核、NAPI 或 VPN 的改动，以真机跑通为完成标准：`make hap && make run`，连接后用浏览器打开一个被墙的站点，并在 `make log` 里看到这条连接命中了代理节点。

- 点界面自己来：`hdc shell uitest dumpLayout` 找按钮坐标，`uitest uiInput click x y` 点击；打开网页用 `aa start -A ohos.want.action.viewData -U <网址>`。布局文件里有输入框中的订阅链接，只解析 Button 节点，设备上和本地的布局文件用完立即删除。
- 崩溃日志只按文件名精确拉取 ArkClash 自己的（`/data/log/faultlog/faultlogger/cppcrash-com.vodstudio.arkclash-*`）。设备上其他应用的日志是用户隐私。
- 符号化：去掉 `-s -w` 另编一份到临时目录，用 `llvm-symbolizer --obj` 解析崩溃地址。

## 平台陷阱

改内核、VPN 或升级 Go / mihomo / gVisor 前，先读 `docs/agents/platform-pitfalls.md`。里面记录了 musl 和 Go 共享库的 TLS 冲突、`protectProcessNet` 管不到 Go 的 socket、SELinux 禁止对 TUN 做 fstat、netlink 被禁用这几个坑，以及各自的补丁和升级时的复查方法。

## 注释

注释用中文。已有的英文注释保持原样，由人工统一改。写注释前读 `docs/agents/comments.md`。

## 安全

- 签名材料只留在本机。DevEco 自动签名会把证书路径和加密后的密码写进 `build-profile.json5` 的 `signingConfigs`，这部分改动一直不暂存；提交时按文件路径精确暂存。
- 订阅链接、controller secret、节点信息只放在应用沙箱里，不进日志、提交、issue 或 PR。

开发计划和进度记在 GitHub Issues。README 面向访客，只写功能、安装和使用，这几样变了才更新它。

## 界面

写或改 ArkUI 页面、组件前读 `docs/agents/ui.md`。

所有可纵向滚动的页面沿用「工具」页的沉浸滚动。一级页面复用 `TabPage`，二级页面复用 `ScrollDestination`。停在顶部时，首项完整显示在标题栏下方。上滑时，正文从固定的标题和操作按钮背后穿过，标题区呈现渐变模糊。标题与按钮避让系统状态栏，按钮保持可点击。验收覆盖首屏、滚动中和回到顶部三个状态。

## Agent skills

### Issue tracker

issue 和 spec 放在 GitHub Issues，用 `gh` 操作。见 `docs/agents/issue-tracker.md`。

### Triage labels

沿用标准的五个状态和 `bug`/`enhancement` 两个类别，另有 `needs-device`。见 `docs/agents/triage-labels.md`。

### Domain docs

单一上下文：根目录 `GLOSSARY.md`（用到时再建）和 `docs/adr/`。见 `docs/agents/domain.md`。
