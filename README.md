<img src="docs/assets/icon.png" width="96" alt="ArkClash 图标">

# ArkClash

[![CI](https://github.com/VOD-Studio/ArkClash/actions/workflows/ci.yml/badge.svg)](https://github.com/VOD-Studio/ArkClash/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

原生 HarmonyOS NEXT 代理客户端。界面用 ArkTS/ArkUI 编写，内核是 [mihomo](https://github.com/MetaCubeX/mihomo)，交互参考 [FlClash](https://github.com/chen08209/FlClash)。

> **早期版本**：目前只支持一个订阅，以及连接和断开。代理组、节点选择、流量和日志等功能还在开发中。

## 为什么做

目标是比同类客户端打开更快、更省电、更稳定、连接更快。

- 内核运行在系统的 VPN 扩展进程里，界面被系统回收也不影响代理。
- 界面进程不加载内核，打开应用时不用等内核启动。
- 内置 Geo 数据，第一次连接不用现场去 GitHub 下载。
- 默认使用 fake-ip DNS，关闭手机上用不到的进程查找。

衡量标准是在同一台手机上和同类客户端对比四项：冷启动到可操作的耗时、开着代理待机 8 小时的耗电、新连接的建立延迟、内核连续 24 小时不重启。测量方法和数据会随版本公布。

## 当前状态

- 下载一个 Clash / mihomo 格式的订阅。
- 连接后，除 ArkClash 自己以外，所有应用的流量都按订阅里的规则分流。
- 在 Pura 70 Ultra（API 26）上验证过，平板和二合一设备还没有测试。

开发计划和进度见 [Issues](https://github.com/VOD-Studio/ArkClash/issues)。

## 安装

需要 HarmonyOS 6.0.2（API 22）及以上的 ARM64 设备。

HarmonyOS 只能安装签过名的应用，目前还没有面向普通用户的安装渠道。[Releases](https://github.com/VOD-Studio/ArkClash/releases) 里每个版本有两个安装包：

| 文件 | 适用于 |
|---|---|
| `ArkClash-<版本>-unsigned.hap` | 有华为开发者账号的用户：用自己的调试证书签名后安装，方法见下面的「从源码构建」 |
| `ArkClash-<版本>-debug-signed.hap` | 维护者的设备：用维护者的调试证书签名，只能装在证书里登记过的设备上 |

下载后可以用同一个 Release 里的 `SHA256SUMS` 校验文件。

## 使用

1. 打开 ArkClash，粘贴订阅链接，点「下载订阅」。
2. 点「连接」。第一次连接时系统会弹出 VPN 授权，选择允许。
3. 显示「已连接」后即生效。更新订阅后，断开再连接一次。

## 从源码构建

需要 DevEco Studio（带 HarmonyOS SDK API 26）、Go（版本见 `.go-version`）和 Python 3。

```sh
make geodata   # 下载 Geo 数据，打包进 HAP
make core      # 交叉编译 mihomo 内核
make hap       # 打包 HAP 到 dist/
make run       # 安装到连着的手机并启动
```

安装到手机前需要签名：用 DevEco Studio 打开项目，在 File → Project Structure → Signing Configs 里用华为账号自动签名。`make help` 列出全部命令。第一次搭环境时，按 [docs/agents/fork-setup.md](docs/agents/fork-setup.md) 逐步完成。

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
