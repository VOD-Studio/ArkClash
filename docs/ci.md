# CI/CD

所有任务都在 GitHub 官方的 Ubuntu 机器上运行，只调用 `Makefile` 的目标。

## 流水线

| workflow | 触发 | 做什么 |
|---|---|---|
| `ci.yml` | PR、推送到 `main` | 编内核并跑 Go/shell/分层检查（`core.yml`）；配置了 Command Line Tools 时再跑 codelinter、打 debug HAP |
| `core.yml` | 被 `ci.yml`、`release.yml` 调用 | 用公开的 OpenHarmony NDK 编 `libclash.so`，上传为 artifact |
| `pr-title.yml` | PR | PR 标题必须是 Conventional Commits |
| `release-please.yml` | 推送到 `main` | 维护发版 PR（版本号、CHANGELOG）；合并发版 PR 后打 tag、建 Release，并调用 `release.yml` |
| `release.yml` | 被 `release-please.yml` 调用，或手动补传 | 打 release 模式的未签名 HAP，配置了签名时再打调试签名 HAP，连同 `SHA256SUMS` 上传到 Release |

两种工具链：

- **内核**用公开的 OpenHarmony SDK 里的 Linux NDK，不需要华为账号，所以 dependabot 和外部 PR 也能跑。`fetch-ohos-ndk.sh` 边下载边解压，取到 NDK 就停，然后缓存。
- **HAP**需要 HarmonyOS 的 Command Line Tools，只能登录华为开发者网站下载，而且不允许公开分发。所以放在一个**私有仓库**的 Release 里，CI 用 token 下载后缓存。

## 变量与密钥

在仓库的 Settings → Secrets and variables → Actions 里配置：

| 名称 | 类型 | 必需 | 内容 |
|---|---|---|---|
| `HARMONYOS_TOOLS_REPO` | Variable | 打 HAP 时 | 存放 Command Line Tools 的私有仓库，如 `VOD-Studio/arkclash-toolchain` |
| `HARMONYOS_TOOLS_TAG` | Variable | 打 HAP 时 | 该仓库里的 Release tag，如 `clt-26.0.0.865` |
| `HARMONYOS_TOOLS_TOKEN` | Secret | 打 HAP 时 | fine-grained token，只授予上面那个仓库的 Contents: Read |
| `HARMONYOS_SIGNING_BUNDLE` | Secret | 否 | 维护者的调试签名包，由 `scripts/ci/export-signing-bundle.sh` 生成 |
| `RELEASE_PLEASE_TOKEN` | Secret | 否 | fine-grained token，本仓库 Contents 和 Pull requests 读写。不配置时用 `GITHUB_TOKEN`，但这样创建的发版 PR 不会触发 CI |

没有配置 `HARMONYOS_TOOLS_REPO` 时，CI 只跑内核和检查，HAP 任务跳过。

## 一次性准备

### Command Line Tools

1. 登录 [developer.huawei.com](https://developer.huawei.com/consumer/cn/download/) 的下载中心，下载 **Command Line Tools** 的 **Linux (64-bit)** 版，记下页面上的 SHA-256。不要下 Linux (ARM64)，GitHub 官方机器是 x86_64。
2. 新建一个私有仓库（比如 `arkclash-toolchain`），创建一个 Release，tag 用 `clt-<版本号>`：
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
4. 在 ArkClash 仓库设置上表的三项：
   ```sh
   gh variable set HARMONYOS_TOOLS_REPO -b VOD-Studio/arkclash-toolchain
   gh variable set HARMONYOS_TOOLS_TAG -b clt-26.0.0.865
   gh secret set HARMONYOS_TOOLS_TOKEN   # 粘贴上一步的 token
   ```

### 调试签名（可选）

在已经用 DevEco Studio 自动签名过的电脑上执行。包里有私钥，只能直接管道进 Secrets：

```sh
scripts/ci/export-signing-bundle.sh | gh secret set HARMONYOS_SIGNING_BUNDLE
```

签名包只能装在证书里登记过的设备上。证书到期、或者新增设备重新生成证书后，再执行一次上面的命令。

## 升级工具链

- **Command Line Tools**：按「一次性准备」第 1、2 步上传新版本，然后更新 `HARMONYOS_TOOLS_TAG`。缓存按 tag 区分，会自动重建。
- **OpenHarmony NDK**：改 `core.yml` 里的 `OHOS_RELEASE` 和 `OHOS_NDK_MEMBER`。文件名可以这样查：
  ```sh
  curl -s https://repo.huaweicloud.com/openharmony/os/<发行版>/ohos-sdk-windows_linux-public.tar.gz | tar -tzf - | grep linux/native
  ```
- **Go**：改 `.go-version`，本机 `make core` 确认补丁能打上，再按 `docs/agents/platform-pitfalls.md` 第 1 条在真机上复查。

## 发版

1. 功能和修复按 Conventional Commits 合并到 `main`。
2. release-please 自动开（或更新）发版 PR，里面是新版本号、`AppScope/app.json5` 的 `versionName` 和 CHANGELOG。`feat` 升次版本号，`fix` 和 `perf` 升修订号；`docs`、`ci`、`build`、`chore` 不触发发版。
3. 审核后合并发版 PR。随后 `release.yml` 构建产物并上传到 Release：
   - `ArkClash-<版本>-unsigned.hap`：给其他人用自己的华为账号签名后安装。
   - `ArkClash-<版本>-debug-signed.hap`：维护者设备直接安装。
   - `SHA256SUMS`
4. 某次上传失败时，在 Actions 里手动运行 Release，填入 tag 补传。

`versionCode` 在构建时由 `versionName` 算出（见 `hvigorfile.ts`），不用手动改。

## 排错

- **HAP 任务被跳过**：没配置 `HARMONYOS_TOOLS_REPO`，或者是 dependabot、外部 fork 发起的 PR（拿不到 secret）。
- **下载 Command Line Tools 报 404 或 403**：token 过期，或者没有授予那个私有仓库的权限。
- **`Command Line Tools 校验失败`**：分卷不全，或者 `SHA256` 文件里的值和上传的包对不上。
- **`SDK 包里没有 ohos-sdk/linux/native-...`**：OpenHarmony 发行版里 NDK 的文件名变了，按「升级工具链」更新。
- **磁盘不够**：缓存没命中时下载加解压峰值约 10GB，`setup-harmonyos-tools` 会先删掉 Android SDK 等预装软件腾出空间。
