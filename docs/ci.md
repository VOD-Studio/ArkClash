# CI/CD

所有任务都在 GitHub 官方的 Ubuntu 机器上运行，只调用 `Makefile` 的目标，本机 `make lint` 和 CI 跑的是同一套检查。设计取舍见 [ADR-0006](adr/0006-layered-ci.md)。

## 流水线

| workflow | 什么时候跑 | 做什么 |
|---|---|---|
| `ci.yml` | PR、合并到 `main`、机器人手动触发 | 分层检查，最后由「CI 通过」汇总，见下一节 |
| `core.yml` | 被其他 workflow 调用 | 用公开的 OpenHarmony NDK 编 `libclash.so`、跑 `go vet`，上传为 artifact |
| `hap.yml` | 被其他 workflow 调用 | 打 HAP（有签名材料时同一次构建产出签名包）、codelinter、检查内容和体积 |
| `release-please.yml` | 合并到 `main` | 维护发版 PR（版本号、CHANGELOG）并触发它的 CI；合并发版 PR 后打 tag、建 Release，调用 `release.yml` |
| `release.yml` | 被 `release-please.yml` 调用，或手动补传 | 干净构建一次，生成校验和与来源证明，上传到 Release |
| `scheduled.yml` | 每周一 10:00（北京时间），可手动 | 更新 Geo 数据、扫描依赖漏洞、不用缓存完整构建；失败时开 issue |
| `codeql.yml` | 内核相关的 PR、`main`、每周 | CodeQL 扫描 Go 代码，结果在 Security → Code scanning |
| `pr-title.yml` | PR 打开、改标题、推送 | PR 标题是否符合提交信息格式（squash 合并时它就是 main 上的提交信息）。不计入「CI 通过」 |

### ci.yml 的分层

```
变更范围 ─┬─ 快速检查 ───────────────┐
          ├─ 内核 ──── HAP ──────────┼─ CI 通过
          └─ 依赖漏洞（不计入汇总）   │
```

| 任务 | 内容 | 跳过条件 |
|---|---|---|
| 变更范围 | `scripts/ci/changes.py` 判断要不要构建、依赖有没有变 | — |
| 快速检查 | 提交信息（每个提交）、shellcheck、actionlint、zizmor、分层规则。不需要工具链，约半分钟 | — |
| 内核 | `make core`、`go vet` | 只改文档 |
| HAP | codelinter、`make hap`、HAP 内容与体积检查，签名包随 artifact 上传 | 只改文档；外部 fork 的 PR（拿不到私有工具链的 token，合并后 `main` 上补跑） |
| 依赖漏洞 | govulncheck，只报告代码真正调用到的漏洞 | 不是改了 Go 依赖的 PR |
| CI 通过 | 汇总以上（依赖漏洞除外）：有失败或取消就失败，跳过不算失败 | — |

- **合并规则只要求「CI 通过」**。以后增减任务只改 `ci.yml` 里它的 `needs`，不用改仓库设置。
- **依赖漏洞暂不计入**：现有依赖还有已知漏洞（见 issue），修完后把 `vuln` 加进「CI 通过」的 `needs`。
- **只改文档**指改动全在 `*.md`、`docs/`、`LICENSE`、`.github/ISSUE_TEMPLATE/`、`.github/CODEOWNERS` 里。
- PR 上新的推送会取消旧的运行；`main` 上每个提交都跑完。合并发版 PR 的那个提交由 `release.yml` 构建，`ci.yml` 不重复构建。
- 运行摘要（Summary）里有 Go、mihomo 版本，以及 HAP 和内核的体积、和 `main` 上次相比的增减。

### 机器人 PR

发版 PR 和 Geo 数据 PR 用 `GITHUB_TOKEN` 创建，GitHub 不会为它们触发 `pull_request`。所以由创建它们的 workflow 再用 `workflow_dispatch` 手动触发 `ci.yml`，「CI 通过」照样挂在 PR 的最新提交上，满足合并规则，不需要个人 token。

如果机器人 PR 上看不到「CI 通过」，在 Actions 里对它的分支手动运行一次 CI。

## 合并规则与仓库设置

仓库是公开的，`main` 用 ruleset「main 保护」：

- 只能通过 PR 合并，merge commit、squash、rebase 都可以，怎么选见 `docs/agents/git.md`「合并」。squash 合并的提交只用 PR 标题、正文为空，发版说明里不会重复。
- 评审意见全部处理（resolve）后才能合并。
- 必须通过「CI 通过」。
- 禁止强推和删除。仓库管理员可以在合并 PR 时绕过，用于紧急情况。

发版 tag（`v*`）用 ruleset「发版 tag 保护」：不能删除，也不能移动。

其他设置：外部贡献者的 PR 首次运行 CI 需要维护者批准；合并后自动删除分支；开启了 Dependabot 告警、secret 扫描和推送拦截、私密漏洞报告。

## Geo 数据

上游 meta-rules-dat 的 latest Release 和 `release` 分支每天都被覆盖，没有可以长期引用的版本。所以：

1. `geodata.lock` 记录每个文件的 sha256 和下载地址，`make geodata` 按它下载并校验。
2. 下载地址是本仓库的预发布 `geodata`，文件名带内容哈希，旧文件保留，历史版本可以重新构建。
3. 每周任务运行 `scripts/update-geodata.sh`：下载上游最新数据、核对上游公布的 sha256、镜像到 `geodata` 预发布、更新锁文件，再开 PR（`bot/geodata` 分支）。合并后，下一个版本的安装包带上新数据。

本机想立刻更新：`make geodata-update`，需要能写本仓库的 `gh` 登录。

## 体积上限

`scripts/ci/check-hap.py` 给 HAP 和 `libclash.so` 设了上限，超出时 HAP 任务失败。内核体积直接影响加载耗时，所以增长要有意识地决定：确实需要时，在 PR 里说明原因，再调高脚本里的 `BUDGET`。

## 变量与密钥

在仓库的 Settings → Secrets and variables 里配置：

| 名称 | 位置 | 必需 | 内容 |
|---|---|---|---|
| `HARMONYOS_TOOLS_REPO` | Actions variable | 打 HAP 时 | 存放 Command Line Tools 的私有仓库，如 `VOD-Studio/arkclash-toolchain` |
| `HARMONYOS_TOOLS_TAG` | Actions variable | 打 HAP 时 | 该仓库里的 Release tag，如 `clt-26.0.0.865` |
| `HARMONYOS_TOOLS_TOKEN` | Actions secret | 打 HAP 时 | fine-grained token，只授予上面那个仓库的 Contents: Read |
| `HARMONYOS_TOOLS_TOKEN` | **Dependabot** secret | 依赖 PR 打 HAP 时 | 同一个 token 再配一份：dependabot 的 PR 读不到 Actions secrets，缺了 HAP 任务会报错提示 |
| `HARMONYOS_SIGNING_BUNDLE` | Actions secret | 否 | 维护者的调试签名包，由 `scripts/ci/export-signing-bundle.sh` 生成 |

没有配置 `HARMONYOS_TOOLS_REPO` 时，HAP 任务跳过，其余照常。

## 一次性准备

### Command Line Tools

1. 登录 [developer.huawei.com](https://developer.huawei.com/consumer/cn/download/) 的下载中心，下载 **Command Line Tools** 的 **Linux (64-bit)** 版，记下页面上的 SHA-256。不要下 Linux (ARM64)，GitHub 官方机器是 x86_64。
2. 新建一个**私有**仓库（华为 SDK 不允许公开分发），创建一个 Release，tag 用 `clt-<版本号>`：
   ```sh
   Z=commandline-tools-linux-x64-26.0.0.865.zip
   echo "<页面上的 SHA-256>  $Z" > SHA256
   # 单个附件不能超过 2GB，超过就分卷，CI 会按文件名顺序拼回去
   split -b 1900m "$Z" "$Z.part-"
   gh repo create VOD-Studio/arkclash-toolchain --private
   gh release create clt-26.0.0.865 -R VOD-Studio/arkclash-toolchain --title "Command Line Tools 26.0.0.865" \
     --notes "华为 SDK，仅供 ArkClash CI 使用，禁止公开" "$Z".part-* SHA256
   ```
3. 在 GitHub 的 Settings → Developer settings → Fine-grained tokens 新建 token：Resource owner 选仓库所在的组织，只选这个私有仓库，权限 Contents: Read-only。
4. 在 ArkClash 仓库设置：
   ```sh
   gh variable set HARMONYOS_TOOLS_REPO -b VOD-Studio/arkclash-toolchain
   gh variable set HARMONYOS_TOOLS_TAG -b clt-26.0.0.865
   gh secret set HARMONYOS_TOOLS_TOKEN                 # 粘贴上一步的 token
   gh secret set HARMONYOS_TOOLS_TOKEN --app dependabot  # 同一个 token 再给 dependabot 一份
   ```

### 调试签名（可选）

在已经用 DevEco Studio 自动签名过的电脑上执行。包里有私钥，只能直接管道进 Secrets：

```sh
scripts/ci/export-signing-bundle.sh | gh secret set HARMONYOS_SIGNING_BUNDLE
```

签名包只能装在证书里登记过的设备上。证书到期、或者新增设备重新生成证书后，再执行一次上面的命令。

## 拿到最新的测试包

`main` 上每次合并都会产出调试签名包（配置了签名时），保留 14 天：

```sh
gh run download -R VOD-Studio/ArkClash -n hap-debug $(gh run list -R VOD-Studio/ArkClash -w CI -b main -s success -L 1 --json databaseId --jq '.[0].databaseId')
```

## 升级工具链

- **Command Line Tools**：按「一次性准备」第 1、2 步上传新版本，然后更新 `HARMONYOS_TOOLS_TAG`。缓存按 tag 区分，会自动重建。
- **OpenHarmony NDK**：改 `.github/actions/setup-core-toolchain/action.yml` 里的 `release`、`member` 和 `path`。文件名可以这样查：
  ```sh
  curl -s https://repo.huaweicloud.com/openharmony/os/<发行版>/ohos-sdk-windows_linux-public.tar.gz | tar -tzf - | grep linux/native
  ```
- **Go**：改 `.go-version`，本机 `make core` 确认补丁能打上，再按 `docs/agents/platform-pitfalls.md` 第 1 条在真机上复查。
- **CI 里的检查工具**：actionlint 的版本和哈希在 `scripts/ci/install-actionlint.sh`，zizmor、govulncheck 的版本在 `scripts/lint.sh`。GitHub Actions 的版本由 dependabot 更新。

## 发版

1. 功能和修复按 Conventional Commits 合并到 `main`。
2. release-please 自动开（或更新）发版 PR，里面是新版本号、`AppScope/app.json5` 的 `versionName` 和 CHANGELOG，并触发它的 CI。`feat` 升次版本号，`fix` 和 `perf` 升修订号；`docs`、`ci`、`build`、`chore` 不触发发版。
3. 审核后合并发版 PR。随后 `release.yml` 从 tag 干净构建一次 release 模式的 HAP，上传到 Release：
   - `ArkClash-<版本>-unsigned.hap`：给其他人用自己的华为账号签名后安装。
   - `ArkClash-<版本>-debug-signed.hap`：同一次构建、用维护者的调试证书签名，维护者设备直接安装。
   - `SHA256SUMS`，以及两个安装包的来源证明。发版说明末尾会自动补上校验方法。
4. 某次上传失败时，在 Actions 里手动运行 Release 补传：「Use workflow from」选这个 tag 本身，再填同一个 tag。这样 workflow、脚本和代码都来自同一个提交；选错了会直接报错。勾选 dry-run 时可以在任意分支上运行，只构建不上传，用来测试发版流程。

`versionCode` 在构建时由 `versionName` 算出（见 `hvigorfile.ts`），不用手动改。

## 排错

- **HAP 任务被跳过**：没配置 `HARMONYOS_TOOLS_REPO`，或者是外部 fork 发起的 PR（拿不到 secret）。
- **dependabot 的 PR 上 HAP 报「没有 HARMONYOS_TOOLS_TOKEN」**：在 Dependabot secrets 里补配，见「变量与密钥」。
- **机器人 PR 上没有「CI 通过」**：见「机器人 PR」。
- **下载 Command Line Tools 报 404 或 403**：token 过期，或者没有授予那个私有仓库的权限。
- **`Command Line Tools 校验失败`**：分卷不全，或者 `SHA256` 文件里的值和上传的包对不上。
- **`SDK 包里没有 ohos-sdk/linux/native-...`**：OpenHarmony 发行版里 NDK 的文件名变了，按「升级工具链」更新。
- **`Signing materials .../material/fd is illegal`**：签名包里混进了多余的文件。用最新的 `export-signing-bundle.sh` 重新导出。
- **`<文件> 校验失败`（Geo 数据）**：`geodata` 预发布里的文件和锁文件对不上，不要手改锁文件，重新运行 `make geodata-update`。
- **HAP 检查报超过上限**：见「体积上限」。
- **磁盘不够**：没有缓存时下载加解压峰值约 10GB，`setup-harmonyos-tools` 会先删掉 Android SDK 等预装软件腾出空间。
- **每周维护开了 issue**：打开 issue 里的链接，看是哪一项失败；修好后关闭 issue。
