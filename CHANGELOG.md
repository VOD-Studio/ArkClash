# Changelog

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
