# Fork 后的首次准备

给接手一个新 fork 的 agent 用。按顺序完成每一步，每一步结尾的「完成标准」满足了再进行下一步。

标了 **【人工】** 的步骤需要人登录华为或 GitHub 网页操作，agent 做不了。遇到时，把要做的事和原因讲清楚交给用户，等用户确认做完再继续。其余步骤 agent 用命令完成，执行前说明要做什么。

## 1. 本机环境

需要：DevEco Studio（带 HarmonyOS SDK API 26）、Go（版本见 `.go-version`）、Python 3、`gh`；最好再装 shellcheck。

- 检查：`go env GOVERSION`、`ls /Applications/DevEco-Studio.app`（macOS）、`gh auth status`。
- 没装 DevEco Studio 时 **【人工】**：从华为开发者网站下载安装，需要登录华为账号。
- **完成标准**：`make lint` 能跑完（缺少 shellcheck、codelinter 时提示跳过，不算失败）。

## 2. 包名

`com.vodstudio.arkclash` 属于上游维护者。fork 用自己的华为账号签名时，通常要换成自己的包名，否则可能因为包名冲突而签名失败。

- 改 `AppScope/app.json5` 的 `bundleName`。脚本和代码都从这里读包名，不用改别处。
- 同步替换文档里写死的包名：`grep -rn "com.vodstudio.arkclash" AGENTS.md docs README.md`。
- **完成标准**：上面的 grep 只剩下你决定保留的地方。

## 3. 构建内核与 HAP

```sh
make geodata
make core
make hap
```

- `make core` 第一次运行会在 `.toolchain/` 里准备打过补丁的 Go 工具链，需要几分钟。失败时先读 `docs/agents/platform-pitfalls.md`。
- **完成标准**：`dist/` 下出现 `ArkClash-<版本>-debug-unsigned.hap`。

## 4. 签名与真机 **【人工】**

1. 手机打开开发者模式和 USB 调试，用数据线直连电脑（扩展坞可能导致识别失败）。
2. 用 DevEco Studio 打开项目，在 File → Project Structure → Signing Configs 里用华为账号自动签名。
3. 签名配置会写进 `build-profile.json5`，这个改动永远不要提交（见 AGENTS.md「安全」）。

然后由 agent 执行 `make hap && make run`，请用户在 App 里粘贴订阅链接、下载订阅、点连接，再用浏览器打开一个被墙的网站。

- **完成标准**：`make log` 里出现 `core ... started`，并能看到一条命中代理节点的 `[TCP]` 连接。

## 5. CI

没有私有的 Command Line Tools 时，CI 也能跑检查和内核编译，只是 HAP 任务会跳过。要启用完整的 CI/CD，按 `docs/ci.md`「一次性准备」完成：

1. **【人工】** 下载 Command Line Tools 的 Linux (64-bit) 版，记下页面上的 SHA-256。
2. agent 校验文件（`shasum -a 256`，和用户给的值对比），建私有仓库并上传（`docs/ci.md` 里的命令）。仓库名和是否新建，先问用户。
3. **【人工】** 新建只读这个私有仓库的 fine-grained token，交给 agent 或者自己执行 `gh secret set HARMONYOS_TOOLS_TOKEN`，再执行一次 `gh secret set HARMONYOS_TOOLS_TOKEN --app dependabot`。
4. agent 设置 `HARMONYOS_TOOLS_REPO`、`HARMONYOS_TOOLS_TAG` 两个变量。
5. 可选：用户同意后，agent 执行 `scripts/ci/export-signing-bundle.sh | gh secret set HARMONYOS_SIGNING_BUNDLE`。输出里有私钥，只能直接管道过去，不能打印或写进文件。
6. Fork 的 Geo 数据锁文件指向上游仓库的镜像，可以直接用；想要自己的镜像，运行 `make geodata-update`。
7. 推送一个分支、开 PR，用 `gh run watch` 看 CI 跑完。
- **完成标准**：PR 上「CI 通过」是绿的，HAP 任务的 artifact 里有未签名的 HAP（配置了签名时还有签名包）。

## 6. 发版与仓库设置（可选）

- 发版流程见 `docs/ci.md`「发版」，不需要额外的 token。
- 想要和上游一样的合并规则（只认「CI 通过」、评审意见处理完才能合并等），按 `docs/ci.md`「合并规则与仓库设置」在 Settings → Rules 里配置。
