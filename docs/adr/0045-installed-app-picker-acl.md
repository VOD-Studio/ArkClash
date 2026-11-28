# ADR-0045：用系统应用选择器添加已安装应用，接受受限 ACL 权限

## 状态

已采纳（2026-11-28 真机验证：HBP-AL00，API 26，选择器列出第三方应用，返回包名与应用名，导入名单后可按名称搜索）。

## 背景

应用访问控制（黑名单 / 白名单）需要用户填写包名。HarmonyOS 不向普通应用开放已安装应用列表：`bundleManager.getAllBundleInfo` 是系统 API，`GET_INSTALLED_BUNDLE_LIST` 为 `system_basic` 且只批给特定场景。0.6.4 之前只能从内置目录勾选或手动 / 剪贴板导入，用户反馈见 #121。

可选路径：

1. **`antifraudPicker.selectFraudApp`**（DeviceSecurityKit，API 19 起，手机 / 平板）：拉起系统应用选择器，用户勾选后返回 `bundleName`、`label` 等，单次最多 50 个。需要受限 ACL 权限 `ohos.permission.USE_FRAUD_APP_PICKER`（`system_basic`，上架时只批给反诈类应用）。
2. **借本机无线调试 / HDC 拿 shell 权限执行 `bm dump -a`**（Shizuku 式）：要在应用里实现 HDC 协议与认证，用户需开开发者模式和无线调试，重启后失效。
3. **从代理连接反查应用**：内核进程查找默认关闭（性能），UID 到包名的映射也是系统 API。

## 决定

采用 1。

- `module.json5` 声明 `USE_FRAUD_APP_PICKER`。调试签名不校验 ACL 用途，DevEco 自动签名会向 AGC 申请并写进调试 Profile 的 `acls.allowed-acls`；ArkClash 只通过 GitHub 分发调试签名包，不上架，不受上架审核限制。
- 选择器入口在应用访问控制页「更多」菜单；结果走现有导入流程（去重、跳过自身、名单上限）。设备不具备 `SystemCapability.Security.Antifraud` 时隐藏入口，接口返回 `1017600002` 时提示改用目录或导入。
- 系统返回的应用名存进 UI 进程的 preferences `access_app_labels`，只用于显示和搜索；保存设置时按两份名单的并集裁剪。VPN 进程只认包名，不读这份数据。

## 后果

- **签名不带这个 ACL 就整包装不上**（`9568289 grant request permissions failed`），不只是功能不可用。自签 `-unsigned.hap` 的 Profile 必须包含该 ACL；DevEco 自动签名满足，手动在 AGC 申请调试 Profile 时要勾选该受限权限。
- DevEco 发现 `~/.ohos/config` 已有同名 `.p7b` 时直接复用，不会补申请新加的 ACL：要先把旧 `.p7b` 挪走再重签，此时证书和密钥也会重新生成，CI 的 `HARMONYOS_SIGNING_BUNDLE` 需重新导出。
- 选择器是 privacycenter 的安全 UIExtension，截图全黑、`uitest dumpLayout` 看不到内部节点，真机验收需人工操作，结果看 hilog。
- 若华为收紧调试 Profile 的 ACL 发放，回退方式是去掉权限声明和入口，目录与导入路径保持可用。
