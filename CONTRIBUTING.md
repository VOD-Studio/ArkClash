# 参与贡献

感谢你愿意改进 ArkClash。人和 AI agent 遵守同一套规范，详细规则在 [AGENTS.md](AGENTS.md) 和它指向的 `docs/agents/` 里，这里只列提 issue 和 PR 时最常用的几条。

## 提 issue

- 用 [新建 issue](https://github.com/VOD-Studio/ArkClash/issues/new/choose) 里的模板，标题写成 `[模块] 描述`，比如 `[vpn] 冷启动时 TUN 创建失败`。
- 带上设备型号、系统版本和 ArkClash 版本；连接问题附上 `make log` 或 hilog 里 `ArkClashCore`、`ClashVpnAbility` 的日志。
- 先给日志打码：订阅链接、节点地址和 secret 都不要出现在 issue 里。
- 安全漏洞走[私密报告](SECURITY.md)，不要公开提 issue。

## 提 PR

1. 第一次搭环境按 [docs/agents/fork-setup.md](docs/agents/fork-setup.md) 完成，`make help` 列出全部命令。
2. 从 `main` 拉分支，分支名和提交信息的格式见 [docs/agents/git.md](docs/agents/git.md)：中文 Conventional Commits，一个提交只做一件事。发版说明由这些提交自动生成，所以每个提交都要写规范。
3. 动到内核、NAPI 或 VPN 时，必须在真机上验证：`make hap && make run`，连接后打开一个需要代理的网站，确认 `make log` 里这条连接走了代理节点。PR 里写明设备和验证结果。
4. 提交前跑 `make lint`，并按 PR 模板填写。
5. 签名配置（`build-profile.json5` 的 `signingConfigs`）只留在本机，不要提交。

外部贡献者第一次提 PR 时，CI 需要维护者批准后才会运行。PR 用 merge commit 合并，保留你的每个提交。

## 行为准则

参与本项目即表示同意遵守[行为准则](CODE_OF_CONDUCT.md)。
