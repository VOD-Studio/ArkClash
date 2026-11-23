# 参与贡献

感谢你愿意改进 ArkClash。人和 AI agent 遵守同一套规范，详细规则在 [AGENTS.md](AGENTS.md) 和它指向的 `docs/agents/` 里，这里只列提 issue 和 PR 时最常用的几条。

## 提 issue

- 用 [新建 issue](https://github.com/VOD-Studio/ArkClash/issues/new/choose) 里的模板，标题写成 `[模块] 描述`，比如 `[vpn] 冷启动时 TUN 创建失败`。
- 带上设备型号、系统版本和 ArkClash 版本；连接问题附上 `make log` 或 hilog 里 `ArkClashCore`、`ClashVpnAbility` 的日志。
- 先给日志打码：订阅链接、节点地址和 secret 都不要出现在 issue 里。
- 安全漏洞走[私密报告](SECURITY.md)，不要公开提 issue。

## 提 PR

1. 第一次搭环境按 [docs/agents/fork-setup.md](docs/agents/fork-setup.md) 完成，`make help` 列出全部命令。
2. 分支名和提交信息的格式见 [docs/agents/git.md](docs/agents/git.md)。提交信息使用中文 Conventional Commits，一个提交只做一件事。发版说明由这些提交自动生成，所以每个提交都要写规范。
3. 动到内核、NAPI 或 VPN 时，必须在真机上验证：`make hap && make run`，连接后打开一个需要代理的网站，确认 `make log` 里这条连接走了代理节点。PR 里写明设备和验证结果。
4. 提交前跑 `make lint`，并按 PR 模板填写。
5. 签名配置（`build-profile.json5` 的 `signingConfigs`）只留在本机，不要提交。

外部贡献者第一次提 PR 时，CI 需要维护者批准后才会运行。维护者按 PR 的内容选择合并方式；squash 合并时，PR 标题会成为 main 上的提交信息和发版说明里的一条，所以 PR 标题也要符合提交信息格式。

## 宿主回归

运行 `make test` 执行宿主业务回归，或用 `make test TESTS="profiles runtime"` 只运行指定分组。使用 Command Line Tools 时先设置 `HARMONYOS_TOOLS_HOME`，脚本会定位 TypeScript 编译器并安装 OHPM 依赖，不必先打包 HAP。

Go 宿主用例使用 `.go-version` 固定的工具链；依赖下载和编译在准备阶段完成，不占用用例执行时限。首次运行需要联网。宿主测试不加载手机共享库，不能替代上述真机验证。

## 真机性能基准

同一台真机安装要测的签名 Release HAP。先选定基准配置、完成 VPN 授权、断开代理并退出首页编辑。测量期间保持亮屏解锁，固定屏幕方向、网络、节点和温度范围。脚本会反复停止和启动 ArkClash，最终断开代理。多设备时设置 `HDC_TARGET`。

```sh
make bench BENCH_ARGS='--scenario startup --label same-hap-a --profile-size 100'
make bench BENCH_ARGS='--scenario startup --label same-hap-b --profile-size 100'
make bench BENCH_ARGS='--compare dist/bench/基线目录 dist/bench/待比目录'
```

完整测量使用 `make bench`。先设置好手机默认浏览器，确认可打开本机回环地址，并将浏览器纳入 VPN。脚本通过 HDC 反向转发提供本机采样页，实际 HTTPS 请求由手机浏览器发出。设置 `BENCH_URL` 为受控 HTTPS 端点，设置 `BENCH_EXIT_IP` 为固定代理出口 IP，规则须将该端点交给这个出口。脚本先验证断开与连接后的出口不同，保留出口错误或连接复用的失败样本。

端点须直连可达、使用手机信任的证书、禁止 HTTP/2 和 HTTP/3，并以 HTTP 200 返回单行请求来源 IP。响应带 `Connection: close`、`Cache-Control: no-store`、`Access-Control-Allow-Origin: *` 和 `Timing-Allow-Origin: *`，接受脚本附加的防缓存查询参数。

- 默认采集 30 次冷启动、冷暖内核各 30 次接入和 100 次新连接。冷启动到可操作以首页 VPN 按钮可见且启用为准，同时保留系统首帧时间。正式验证 p95 < 500 ms 前，可用 DevEco Launch 跟踪核对按钮时点。
- 冷接入保留正常的自动预热。若点击时内核已经就绪，该轮标记为 `core_phase_unconfirmed`。接入终点为 UI 确认 TUN 已运行。首个 HTTPS 成功包含浏览器打开采样页的时间，报告用 `tun_to_probe_ms` 单列 TUN 确认到浏览器发起请求的间隔。
- `dist/bench/` 下的 `samples.csv` 和 `summary.json` 保留各轮数据和汇总。新连接可能命中 DNS 缓存，因此 DNS 耗时可以为零。先用同一 HAP 跑两组观察波动，再轮换测新旧版本。旧版需带同一套测量标记。8 小时耗电和 24 小时稳定性仍按[真机测量规程](https://github.com/VOD-Studio/ArkClash/issues/54)单独验收。

## 行为准则

参与本项目即表示同意遵守[行为准则](CODE_OF_CONDUCT.md)。
