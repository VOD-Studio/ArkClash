# CI/CD

所有任务都在 GitHub 官方的 Ubuntu 机器上运行，只调用 `Makefile` 的目标。

## 流水线

| workflow | 触发 | 做什么 |
|---|---|---|
| `ci.yml` | PR、推送到 `main` | 编内核并跑 Go/shell/分层检查（`core.yml`）；配置了 Command Line Tools 时再跑 codelinter、打 debug HAP |
| `core.yml` | 被 `ci.yml` 调用 | 用公开的 OpenHarmony NDK 编 `libclash.so`，上传为 artifact |
| `pr-title.yml` | PR | PR 标题必须是 Conventional Commits |

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

## 升级工具链

- **Command Line Tools**：按「一次性准备」第 1、2 步上传新版本，然后更新 `HARMONYOS_TOOLS_TAG`。缓存按 tag 区分，会自动重建。
- **OpenHarmony NDK**：改 `core.yml` 里的 `OHOS_RELEASE` 和 `OHOS_NDK_MEMBER`。文件名可以这样查：
  ```sh
  curl -s https://repo.huaweicloud.com/openharmony/os/<发行版>/ohos-sdk-windows_linux-public.tar.gz | tar -tzf - | grep linux/native
  ```
- **Go**：改 `.go-version`，本机 `make core` 确认补丁能打上，再按 `docs/agents/platform-pitfalls.md` 第 1 条在真机上复查。

## 排错

- **HAP 任务被跳过**：没配置 `HARMONYOS_TOOLS_REPO`，或者是 dependabot、外部 fork 发起的 PR（拿不到 secret）。
- **下载 Command Line Tools 报 404 或 403**：token 过期，或者没有授予那个私有仓库的权限。
- **`Command Line Tools 校验失败`**：分卷不全，或者 `SHA256` 文件里的值和上传的包对不上。
- **`SDK 包里没有 ohos-sdk/linux/native-...`**：OpenHarmony 发行版里 NDK 的文件名变了，按「升级工具链」更新。
- **磁盘不够**：缓存没命中时下载加解压峰值约 10GB，`setup-harmonyos-tools` 会先删掉 Android SDK 等预装软件腾出空间。
