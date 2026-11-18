<img src="docs/assets/icon.png" width="96" alt="ArkClash 图标">

# ArkClash

[![CI](https://github.com/VOD-Studio/ArkClash/actions/workflows/ci.yml/badge.svg)](https://github.com/VOD-Studio/ArkClash/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

原生 HarmonyOS NEXT 代理客户端。界面用 ArkTS/ArkUI 编写，内核是 [mihomo](https://github.com/MetaCubeX/mihomo)，手机端交互以 [FlClash v0.9.3](https://github.com/chen08209/FlClash/tree/be84736605527034689c95bf27828ff27d912c5e) 为对齐基准。

> **早期版本**：已接入仪表盘、代理、多配置、Geo 资源及连接/DNS 诊断。新增功能尚待统一真机验收；日志等功能仍在开发。

## 为什么做

目标是比同类客户端打开更快、更省电、更稳定、连接更快。

- 内核运行在系统 VPN 扩展进程，界面经 controller 和沙箱文件控制。扩展被销毁后不承诺继续代理。
- 界面进程不加载内核，打开应用时不用等内核启动。
- 内置 Geo 数据，核心预热不用现场去 GitHub 下载。
- 默认使用 fake-ip DNS，关闭手机上用不到的进程查找。

衡量标准是在同一台手机上和同类客户端对比四项：冷启动到可操作的耗时、开着代理待机 8 小时的耗电、新连接的建立延迟、内核连续 24 小时不重启。测量方法和数据会随版本公布。

## 当前状态

- 仪表盘：独立控制 VPN 连接与断开、出站模式、实时速率与连接统计、出口 IP 和服务连通性检查。
- 代理：分组与节点浏览、按配置保存选择、未连接测速、搜索排序及列表/标签视图；内核未就绪时可显式启动。
- 配置：订阅与本地文件导入、切换、更新、重命名、复制、删除和内容编辑。
- 资源：查看 MMDB、ASN、GEOIP、GEOSITE 的本地信息，编辑/恢复/复制来源地址，连接后单项或全部更新，按小时间隔自动更新。
- 工具：连接页合并「运行中」与「最近请求」，支持搜索、筛选、分组、宽屏表格和关闭连接；DNS 页查看被动查询、缓存命中与上游结果，并可清理 DNS 缓存。
- 基础 VPN 连接曾在 Pura 70 Ultra（API 26）验证；本轮无 TUN 预热、手机驻留、新增资源/诊断页面及性能指标尚未完成真机验收。

开发计划和进度见 [Issues](https://github.com/VOD-Studio/ArkClash/issues)。

## 安装

需要 HarmonyOS 7（API 26）及以上的 ARM64 设备。

HarmonyOS 只能安装签过名的应用，目前还没有面向普通用户的安装渠道。安装包分为两种，发布附件见 [Releases](https://github.com/VOD-Studio/ArkClash/releases)：

| 文件 | 适用于 |
|---|---|
| `ArkClash-<版本>-unsigned.hap` | 有华为开发者账号的用户：用自己的调试证书签名后安装，方法见下面的「从源码构建」 |
| `ArkClash-<版本>-debug-signed.hap` | 维护者的设备：用维护者的调试证书签名，只能装在证书里登记过的设备上 |

下载后可以用同一个 Release 里的 `SHA256SUMS` 校验文件。

## 使用

1. 打开应用会在首帧之后尝试预热内核，首次会提前出现系统 VPN 授权框；允许授权不会自动接管系统流量。拒绝后本次应用会话不自动重复请求，可在代理页点「启动内核」重试。
2. 在「配置」添加订阅或导入本地 Clash / mihomo YAML。选好配置后回到仪表盘点「连接」，才开启系统流量接管。
3. 内核就绪后可在「代理」选择节点，或对单节点、分组及 picker 发起真实测速，不要求先连接 VPN。普通断开保留内核、节点选择和测速结果。
4. 在「配置」更新订阅。只要核心在线就尝试热切换，即使 VPN 未连接；失败时保留原运行配置并显示错误。
5. 在「工具 → 资源」管理 Geo。离线可查看文件和保存设置，连接后才可下载；首卡可开关自动更新，开启后可修改周期，默认关闭、间隔 24 小时。保存 URL 不会立即下载，恢复默认只修改编辑草稿；页面离开后内核中的更新继续执行。
6. 在「工具 → 连接 / DNS 查询」查看诊断记录。记录仅驻留内存，只在对应页面可见时采集，隐藏或断线期间不补回；「最近请求」不是完整历史。清 DNS 缓存不删除记录，也不清除 FakeIP 映射。

## 从源码构建

需要 DevEco Studio 或 Command Line Tools（带 HarmonyOS SDK API 26）、Go（版本见 `.go-version`）和 Python 3。使用 Command Line Tools 时设置 `HARMONYOS_TOOLS_HOME`；纯命令行编译内核还需设置 `OHOS_SDK` 指向其 OpenHarmony SDK 目录。

```sh
make geodata   # 下载 Geo 数据，打包进 HAP
make core      # 交叉编译 mihomo 内核
make hap       # 打包 HAP 到 dist/
make run       # 安装到连着的手机并启动
```

安装到手机前需要签名：用 DevEco Studio 打开项目，在 File → Project Structure → Signing Configs 里用华为账号自动签名。`make help` 列出全部命令。第一次搭环境时，按 [docs/agents/fork-setup.md](docs/agents/fork-setup.md) 逐步完成。

默认构建 ARM64。开发用 x86_64 模拟器可显式选择 ABI：

```sh
make core ABI=x86_64
make core-smoke ABI=x86_64  # 已连接的模拟器；仅验证原生加载和多线程 C API
make hap ABI=x86_64
# 配置签名后：
make run ABI=x86_64
```

x86_64 包为 `dist/ArkClash-<版本>-debug-x86_64-unsigned.hap`，不会覆盖 ARM64 包。不同 ABI 的 HAP 不要并发构建。模拟器原生加载已验证，签名后的应用/VPN 验收仍待完成；模拟器结果不能替代 ARM 真机性能和稳定性验证。

## 文档

| 文档 | 内容 |
|---|---|
| [架构](docs/architecture.md) | 进程划分、连接流程、目录分层 |
| [决策记录](docs/adr/) | 关键技术取舍和理由 |
| [CI/CD](docs/ci.md) | 流水线、密钥配置、发版流程 |
| [AGENTS.md](AGENTS.md) | 开发规范，人和 AI agent 共用 |

## 参与贡献

欢迎提 issue 和 PR，先读[贡献指南](CONTRIBUTING.md)。安全漏洞请按[安全策略](SECURITY.md)私密报告。

## 致谢

- [mihomo](https://github.com/MetaCubeX/mihomo)：代理内核
- [FlClash](https://github.com/chen08209/FlClash)：交互设计参考
- [sing-tun](https://github.com/SagerNet/sing-tun) 和 [gVisor](https://github.com/google/gvisor)：TUN 协议栈
- [meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)：内置的 Geo 数据

## 许可证

[GPL-3.0](LICENSE)

## 免责声明

本项目仅用于学习和研究网络技术。请遵守你所在地区的法律法规，使用本软件产生的后果由使用者自行承担。
