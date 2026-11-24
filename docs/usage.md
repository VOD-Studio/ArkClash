# ArkClash 使用指南

## 安装发布包

安装需要 HarmonyOS 7（API 26）及以上的 ARM64 设备。电脑需安装带 HarmonyOS SDK API 26 的 DevEco Studio 或 Command Line Tools，`make install` 会使用 SDK 中的 `hdc`。[工具链设置](../README.md#从源码构建)

1. 下载所需版本的 `ArkClash-<版本>-unsigned.hap`，用同一发布页的 `SHA256SUMS` 校验。下载并解压同一版本的源码，后续安装会用到其中的 Makefile。[GitHub Releases](https://github.com/VOD-Studio/ArkClash/releases)
2. 在设备上开启开发者模式和 USB 调试，并连接电脑。准备调试密钥库（`.p12`）、证书（`.cer`）和调试 Profile（`.p7b`）。Profile 需匹配包名 `com.vodstudio.arkclash` 及调试证书，并包含这台设备的 UDID。[华为调试 Profile 指南](https://developer.huawei.com/consumer/cn/doc/App/agc-help-debug-profile-0000002248181278/)
3. 在项目根目录执行以下命令。把示例路径、密钥别名和 `<版本>` 换成实际值。`hap-sign-tool.jar` 在 HarmonyOS SDK 所附 OpenHarmony SDK 的 `toolchains/lib` 目录下，签名时按提示输入密码。[华为命令行签名指南](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/ide-hmos-command-line-building-app/)

   ```sh
   mkdir -p dist
   java -jar "/path/to/hap-sign-tool.jar" sign-app \
     -mode localSign -signAlg SHA256withECDSA -compatibleVersion 26 -pwdInputMode 1 \
     -keystoreFile "/path/to/debug.p12" -keyAlias "debugKey" \
     -appCertFile "/path/to/debug.cer" -profileFile "/path/to/debug.p7b" \
     -inFile "/path/to/ArkClash-<版本>-unsigned.hap" \
     -outFile "dist/ArkClash-<版本>-release-signed.hap"
   ```

4. 签名成功后，执行 `make install MODE=release`。

如果设备已登记在维护者的调试 Profile 中，可以下载并校验 `ArkClash-<版本>-debug-signed.hap`，将它重命名为 `ArkClash-<版本>-release-signed.hap`，放进同版本源码的 `dist/` 目录，再执行 `make install MODE=release`。

如果账号无法为原包名申请调试 Profile，在源码的 `AppScope/app.json5` 中把 `bundleName` 改成自己的包名，再用 DevEco Studio 自动签名并构建。[从源码构建](../README.md#从源码构建)

## 配置与订阅

- 在「配置」扫码或从相册导入订阅和节点。批量导入时，多条节点分享链接会合成一份配置。也可以在「添加 → 新建自定义配置」从空白组装，或通过「导入配置结构」打开已有 YAML。自定义配置可编辑代理组、成员、拨号链和规则。
- 网页可以用 `clash://install-config?url=<经过 URL 编码的订阅地址>` 打开导入表单。`clashmeta` 和 `flclash` 协议也受支持，确认保存后开始下载。订阅卡片的「更多 → 订阅二维码」可展示订阅地址供扫码分享。
- 导入 age 加密订阅时，在单条链接表单填写 age 私钥。手动或自动更新会使用已保存的私钥，可从配置编辑页更换。
- 当前订阅更新后，只要内核在线就会尝试热切换。应用失败时保留原运行配置并显示错误。
- 内核就绪后可在「代理」选择节点，或在开启 VPN 前为单节点和分组测速。普通断开会保留内核、节点选择和测速结果。

## 资源与诊断

- 在「工具 → 资源」管理 MMDB、ASN、GEOIP 和 GEOSITE。离线可查看文件和保存设置，连接后可按项或全部下载。自动更新默认开启，间隔 24 小时，已保存的开关和周期随升级保留。保存来源地址后，下次更新才使用该地址。编辑页的「恢复默认」只修改草稿。离开资源页后下载继续执行。
- 在「工具 → 连接」查看运行中的连接和最近请求，可搜索、筛选、分组或关闭连接。「工具 → DNS 查询」可查看查询、缓存命中和上游结果。内核就绪且应用保持采集连接时，离开诊断页或退到后台后也会继续采集近期记录，记录仅存于内存。页面在前台可见时才实时刷新列表。清理 DNS 缓存会保留诊断记录和 Fake-IP 映射。
- 开启日志捕获后，可在「工具 → 日志」筛选、暂停浏览和导出近期记录。
- 在仪表盘顶部点「运行状态」，可查看内核和 Geo 下载进度，并检查、下载、校验及保存 GitHub 发布的 HAP。应用启动后会自动检查一次更新，可在「工具 → 常规」关闭。

## 进阶配置

- 在「工具 → 进阶配置 → 脚本」新建或导入 JavaScript，再从「配置 → 更多 → 覆写」选中脚本。`main(config)` 接收完整配置，返回的配置会继续应用附加规则。
- 在「配置 → 更多 → 覆写 → 配置附加规则」管理单份配置的规则、选择 MATCH 目标和停用指定全局规则。添加规则时可选用或新建命名出口，再到配置的「命名出口」为它指定节点或代理组。当前配置可在覆写页立即应用，退出该页时也会应用已保存的更改。
- 在「工具 → 进阶配置 → DNS」逐项覆写上游策略、Fallback 筛选、Fake-IP 和缓存设置。移除覆写项即可恢复配置值。在「网络 → 绕过 VPN 的应用」填写应用包名，重连后这些应用走系统网络。
- 在「工具 → 常规」设置入站端口和认证、外部控制器、订阅 User-Agent、全局 Hosts、测速超时和切节点后的连接清理。「追加系统 DNS」保留已有 DNS 上游，并加上当前默认网络提供的 DNS。

### 自定义资源

打开「工具 → 进阶配置 → 自定义资源」。

- 在「代理」维护本地节点库，支持协议表单和批量编辑分享链接。
- 在「规则集」新建规则集，或从文件和 URL 导入 YAML、Text、MRS。保存后在「附加规则」选择 `RULE-SET`、规则集和出站策略。远程规则集可手动同步。
- 在「筛选」管理正则预设。编辑配置内容时点「插入筛选」，选中代理组或代理集合，再选包含或排除匹配项，最后保存配置。
- 在「图标集」从文件或 URL 导入图标集 JSON。编辑配置文件时点「选择图标」，可给代理组选图标、输入图标 URL 或移除图标。

## 主题与备份

- 在「工具 → 主题」实时预览深浅色、纯黑、系统和自定义配色，还可调整导航栏、页签动效、沉浸光感、字体与字号。
- 在「工具 → 备份与恢复」导出本地 ZIP，或绑定 WebDAV 后手动上传与恢复。恢复时可选「仅配置及资源」或「全部数据」，并选择合并或覆盖。ZIP 未加密，请按敏感文件保存。
