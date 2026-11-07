# 安全策略

## 支持的版本

只有[最新的 Release](https://github.com/VOD-Studio/ArkClash/releases/latest) 会收到安全修复。

## 报告漏洞

请通过 GitHub 的[私密漏洞报告](https://github.com/VOD-Studio/ArkClash/security/advisories/new)提交，不要公开提 issue 或 PR。报告里请写明：

- 受影响的版本和设备
- 复现步骤
- 可能造成的影响，比如流量绕过代理、DNS 泄露、本机 controller 被其他应用访问

不要附上你自己的订阅链接、节点地址或 secret。

维护者会尽快回复，修复发版后公开致谢（如果你愿意）。

## 范围

- ArkClash 自己的代码：ArkTS 界面、VPN 扩展、NAPI 桥、`core/` 下的 Go 封装、构建与发版流程。
- mihomo、sing-tun、gVisor 等上游项目本身的漏洞，请报告给对应项目；如果 ArkClash 因为使用方式而受影响，也欢迎告诉我们。
