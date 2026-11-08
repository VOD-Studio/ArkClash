# Changelog

## 未发布

### 修复

* **core:** 逐 socket 绑定当前物理网络，修复 Go 出站回到 TUN 导致连接递归和内存暴涨。
* **ui:** 保留服务品牌图标原色并补齐 ChatGPT，将 AI 集中排列在 Google 后，保留已有显隐设置。
* **ui:** 区分主动滚动与弹簧回弹，避免快速滑动后底部栏误恢复。

### 性能

* **ui:** 使用系统异步接口采集界面进程内存，避免在 ArkTS 主线程同步读取 smaps。

## [0.4.0](https://github.com/VOD-Studio/ArkClash/compare/v0.3.0...v0.4.0) (2026-11-07)


### 新增

* **core:** 在 controller 上提供 ArkClash 命令和热切换 ([a51aa88](https://github.com/VOD-Studio/ArkClash/commit/a51aa88d5ecf6c93fda9939701f9192b30142845))
* **profiles:** 多订阅配置管理 ([a914028](https://github.com/VOD-Studio/ArkClash/commit/a9140283e1e4cb27713b5ca337f4382b4d102106))
* **profiles:** 多订阅配置管理 ([#48](https://github.com/VOD-Studio/ArkClash/issues/48)) ([f53a689](https://github.com/VOD-Studio/ArkClash/commit/f53a6892d65a758c881db354aa0bc464ea52b206))


### 修复

* **ui:** 修复标题栏菜单不显示 ([6df027a](https://github.com/VOD-Studio/ArkClash/commit/6df027a80567b35866006a0c725654a6c6a165b0))

## [0.3.0](https://github.com/VOD-Studio/ArkClash/compare/v0.2.0...v0.3.0) (2026-11-07)


### 新增

* **ui:** 按 UI Design Kit 重做导航和首页 ([2c5dfa9](https://github.com/VOD-Studio/ArkClash/commit/2c5dfa9044ca52cd7ddedca37612f50bbaa947df))
* **ui:** 新增沉浸光感页面骨架和通用组件 ([cbbc086](https://github.com/VOD-Studio/ArkClash/commit/cbbc086ef4ef4630900f45857247e3cec34c401a))
* **ui:** 新增界面访问内核的连接状态、流量推送和查询 ([5419676](https://github.com/VOD-Studio/ArkClash/commit/541967683cd3bb298920e9f5eb221d979c985caa))
* **ui:** 新增连接统计、内存、服务检测和局域网代理的数据接口 ([62c89e7](https://github.com/VOD-Studio/ArkClash/commit/62c89e7ea52454fb7365def274acfa6eba9a0551))
* **ui:** 服务状态支持更多服务、品牌图标、排序和显隐 ([7f7b943](https://github.com/VOD-Studio/ArkClash/commit/7f7b943989641ae39ba23499655719f3bf707009))
* **ui:** 重做首页与导航 ([c9dead4](https://github.com/VOD-Studio/ArkClash/commit/c9dead4e370bf4b670fca9bf1055927b97eb0db4))
* **ui:** 首页新增内网 IP、服务状态、连接统计和内存四张卡 ([ed809c5](https://github.com/VOD-Studio/ArkClash/commit/ed809c596a8257a3279f86c7d211a58dedd26d01))


### 修复

* **core:** 修复出站回环导致的内存暴涨 ([11f12fe](https://github.com/VOD-Studio/ArkClash/commit/11f12fe49b673e5390119ca38eadf0e4ede0e04a))
* **core:** 绑定出站物理网络以阻止 VPN 回环和内存暴涨 ([57adf32](https://github.com/VOD-Studio/ArkClash/commit/57adf32891037f6c45904e4433e8611a5a478db7))
* **ui:** 修正服务品牌图标与 AI 排序 ([8c21649](https://github.com/VOD-Studio/ArkClash/commit/8c2164935e8075ebf83b298f3cb28babb8332356))
* **ui:** 修正服务展示与底栏滚动交互 ([ef321c2](https://github.com/VOD-Studio/ArkClash/commit/ef321c23d77028a3dc5f3445676aebd1a6f53079))
* **ui:** 忽略回弹引起的底栏方向变化 ([8bc8b18](https://github.com/VOD-Studio/ArkClash/commit/8bc8b18c3d800464307dc934a68551ab908a45d8))
* **ui:** 页面往下滚时收起页签栏、展开连接条 ([1fc9b04](https://github.com/VOD-Studio/ArkClash/commit/1fc9b04deede010d9528c520b3049a5e6849ac8f))


### 性能

* **ui:** 异步采集界面进程内存 ([7d3a71a](https://github.com/VOD-Studio/ArkClash/commit/7d3a71a87a1f17d8d8e08584f65832dfcbc91577))

## [0.2.0](https://github.com/VOD-Studio/ArkClash/compare/v0.1.2...v0.2.0) (2026-11-07)


### 新增

* **ui:** 换用新的应用图标 ([4f9bd78](https://github.com/VOD-Studio/ArkClash/commit/4f9bd78b09d57f4a28ecb6a51c1af475a2e8b7ca))

## [0.1.2](https://github.com/VOD-Studio/ArkClash/compare/v0.1.1...v0.1.2) (2026-11-07)


### 修复

* **ci:** 导出签名包时不带入 macOS 的扩展属性文件 ([6cd46f3](https://github.com/VOD-Studio/ArkClash/commit/6cd46f379c6fc9cfc618f67f0e4f32e41b5188ea))
* **ci:** 导出签名包时不带入 macOS 的扩展属性文件 ([dc4f2b4](https://github.com/VOD-Studio/ArkClash/commit/dc4f2b4204b38a90c9f51f3e40e378fdbd1dee20))
* **scripts:** 修复变量后紧跟中文时被 bash 误读 ([2c25ece](https://github.com/VOD-Studio/ArkClash/commit/2c25ece0c0bdbac484d45223438c9a227f384f0a))

## [0.1.1](https://github.com/VOD-Studio/ArkClash/compare/v0.1.0...v0.1.1) (2026-11-07)


### 修复

* **ci:** 保留 SDK 的 previewer 组件并让缓存随下载脚本失效 ([052e2b7](https://github.com/VOD-Studio/ArkClash/commit/052e2b7837339b7180854b57ced874901023ca3a))
* **core:** 关闭回环检测以恢复 UDP 直连 ([7beaee5](https://github.com/VOD-Studio/ArkClash/commit/7beaee528ed9b8435b0f8654d58fe84625917ffe))
* **core:** 绕过 SELinux 对 TUN fd 的 fstat 限制 ([cea9db6](https://github.com/VOD-Studio/ArkClash/commit/cea9db635b2cc67bc37810d882afcb6fa8bde881))
* **geodata:** 按版本标记判断内置 Geo 数据是否需要更新 ([b2a27b0](https://github.com/VOD-Studio/ArkClash/commit/b2a27b044fd870011d752a87ad3960968149e444))
* **scripts:** make install 只安装本次构建的签名包 ([47e64f8](https://github.com/VOD-Studio/ArkClash/commit/47e64f8072ce00058aec058292dc305b9ee918e8))
* **scripts:** 修复 TLS 重定位检查在命中时反而放行 ([5e19c38](https://github.com/VOD-Studio/ArkClash/commit/5e19c3801ce42c1aa87dc6f9d11771f271258b3e))
* **scripts:** 全新环境下先下载 gVisor 模块再定位目录 ([33275a0](https://github.com/VOD-Studio/ArkClash/commit/33275a036531852acf38558e0c9d14e138bf3da0))
* **toolchain:** 用打补丁的 Go 工具链构建内核 ([6a2110a](https://github.com/VOD-Studio/ArkClash/commit/6a2110aed36235771858490c6111950b1f1b91da))
* **vpn:** 内置 Geo 数据避免启动时现场下载 ([81aa2e5](https://github.com/VOD-Studio/ArkClash/commit/81aa2e5b315dc357da4e52081c3c9049f75b4570))
* **vpn:** 按 UID 把本应用排除在 VPN 之外 ([e88756b](https://github.com/VOD-Studio/ArkClash/commit/e88756bdefa398d2ece7b2f36fe3dba873a894de))
* **vpn:** 显式标注内核启动返回的 Promise 类型 ([4573fd9](https://github.com/VOD-Studio/ArkClash/commit/4573fd928d0666963b0d110c19a7cc0fd5538329))
* 修复鸿蒙真机上的内核加载与连接问题 ([f1fcc1c](https://github.com/VOD-Studio/ArkClash/commit/f1fcc1c0051d58fc6b7deef0d836c7a8e9482e8b))


### 性能

* **vpn:** 异步复制内置的 Geo 数据 ([59deaa0](https://github.com/VOD-Studio/ArkClash/commit/59deaa0053baf2fd46e70886d05f2f8f1ab0406e))


### 重构

* **ui:** 按进程与职责分层整理 ArkTS 目录 ([5e57600](https://github.com/VOD-Studio/ArkClash/commit/5e576001f90b363aae70c80f03d7369185799d1c))
