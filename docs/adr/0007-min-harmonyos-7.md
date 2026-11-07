# 0007 最低支持 HarmonyOS 7（API 26），界面以 UI Design Kit 为准

- 状态：已采纳（2026-11-07）

## 背景

1.0 的界面以 HarmonyOS 7 的沉浸光感为核心（#21）。真机对照华为、QQ 音乐等官方适配过的应用后，需要的效果有：悬浮胶囊页签栏和它的材质、适人握持、页签栏随页面滚动收起并展开迷你栏、标题栏随内容滚动的沉浸式渐变模糊。

- ArkUI 原生组件在 API 26 才有悬浮页签栏（`Tabs.barFloatingStyle`）和 `uiMaterial`，而且只有其中一部分：标题栏只有均匀模糊，没有页签栏收起和迷你栏。
- UI Design Kit 的 `HdsTabs`、`HdsNavigation` 从 6.1.0(23) 起提供上面全部能力（`bindScroller`、`miniBar`、`IMMERSIVE_GRADIENT_BLUR`、`systemMaterialEffect`）。

在这之前最低版本是 API 22（HarmonyOS 6.0.2），起因是 `VpnConnection.protectProcessNet()`。继续支持 API 22–25 就要在页面边界按 `sdkApiVersion` 分出两套组件树，API 22 上也完全没有材质。调研见 #20（分支 `research/ui-material`）。

截至 2026-10-27，API 26 的存量设备占比约 77%，而且还在随公测升级快速增长（同一份调研）。

## 决定

- `compatibleSdkVersion` 提到 `26.0.0`，不再支持 HarmonyOS 6.x，不写版本分支。
- 界面以官方 UI Design Kit 为准：页签栏用 `HdsTabs`，一级页面的标题栏用 `HdsNavigation`；HDS 没有的才用 ArkUI 原生组件。应用级打开系统材质（`module.json5` 的 `ohos.arkui.UIMaterial.state` 设为 `enable`），系统组件和弹层统一使用沉浸光感材质。

## 后果

- 只有一套组件树，不用担心低版本设备加载 HDS 组件时崩溃。
- UI Design Kit 声明仅支持中国境内。1.0 只发安装包、不上架，HarmonyOS 7 手机也只有中国大陆机型，不影响交付；以后上架境外再复核。
- HDS 的材质和模糊效果在模拟器上不生效，只能真机验证。
- HarmonyOS 6.x 的设备装不上新版本，只能停在 0.2.x。README 的安装要求同步改成 HarmonyOS 7。
- 材质用哪种强度、对耗电的影响多大，等 #28 的真机数据，由 #29 决定。
