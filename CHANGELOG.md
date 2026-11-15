# Changelog

## 未发布

### 修复

* **core:** 逐 socket 绑定当前物理网络，修复 Go 出站回到 TUN 导致连接递归和内存暴涨。
* **runtime:** 用系统进程事实恢复异常退出的 VPN，取消启动时拒绝迟到成功，未知状态保留停止确认入口。
* **ui:** 抽屉和卡片背景直接引用成员 Builder，修复弹出详情时的组件宿主丢失。
* **ui:** 卡片编辑退出时停止原生循环动画，保存后的呈现更新移出 Monitor，页签和出站模式动效遵循减少动态设置。
* **ui:** 仪表盘卡片改用原生柔和阴影，圆角裁剪只作用于内部内容。
* **ui:** 状态卡补齐真实 IP 类型与质量、固定尺寸骨架屏和原生圆形启停动效。
* **ui:** 代理组摘要按显式叠放布局排列头像，为组数保留宽度。
* **ui:** 网络速度折线使用实际采样和明确绘制尺寸，移除主卡中的错误说明文字。
* **ui:** 服务状态按用户选择最多预览四项，管理面板同步标识首页展示项。
* **ui:** 尚未实现的连接、请求与 DNS 统计明确显示开发中，不再代用其他口径。
* **ui:** 修正配置用量波形的绘制尺寸与坐标，避免显示成割裂的色块。
* **ui:** 首页配置卡在当前页打开详情抽屉，编辑和导入继续使用原有表单与保存保护。
* **ui:** 三页标题按钮统一采用原生圆形沉浸光感材质，保留原有图标。
* **ui:** 代理分组以实际布局高度展开和收起，保留连续浅色外层与节点选中标记；吸顶只遮挡本组内容，保留页面沉浸滚动，修正标题圆角漏出和收起轮廓跳变。
* **ui:** 代理分组折叠时保留同一个原生标题，只切换节点区域，避免文字因标题重建而闪烁。
* **ui:** 代理页只保留分组列表，移除风格切换和旧页签偏好分支；保留排序、布局、尺寸和图标设置，以及首页节点选择器的分组切换。
* **ui:** 代理节点增加触点扩散与松开淡出，拖动时取消反馈，复用时清理旧按压状态；保持浅色卡片、独立选中标记与测速操作，分组标题继续使用原生按压。
* **ui:** 精简仪表盘和抽屉中的重复说明，保留可操作的失败反馈和真实数据状态。
* **ui:** 保留服务品牌图标原色并补齐 ChatGPT，将 AI 集中排列在 Google 后，保留已有显隐设置。
* **ui:** 区分主动滚动与弹簧回弹，避免快速滑动后底部栏误恢复。
* **ui:** 按固定 FlClash v0.9.3 与 Prism 源码调整仪表盘、代理和配置页的布局、卡片、字体及操作入口，保留原生浮动栏图标、出站模式切换组件、模糊和沉浸光感。
* **ui:** 配置失败结果逐行懒加载，为重复无效输入保留独立行，避免批量失败时漏行。

### 性能

* **ui:** 使用系统异步接口采集界面进程内存，避免在 ArkTS 主线程同步读取 smaps。

## [0.5.0](https://github.com/VOD-Studio/ArkClash/compare/v0.4.0...v0.5.0) (2026-11-15)


### 新增

* **client:** 同步运行会话与节点选择状态 ([19e8fc9](https://github.com/VOD-Studio/ArkClash/commit/19e8fc952c571913404fc8ce5b74bad4c398840d))
* **core:** 提供配置会话的控制事务 ([66b6584](https://github.com/VOD-Studio/ArkClash/commit/66b6584e36dd660bd3310e5a4e3e5f292c4fe50c))
* **profiles:** 实现按配置存储与更新事务 ([1303820](https://github.com/VOD-Studio/ArkClash/commit/1303820a2e7637749b2de0946ce8c6d94d6a6862))
* **proxies:** 接入分组节点页面与选择弹层 ([18bc298](https://github.com/VOD-Studio/ArkClash/commit/18bc2981fbf1466ba2605f2523cd5e2f7f9307a4))
* **ui:** 接通仪表盘与配置页面 ([98bf565](https://github.com/VOD-Studio/ArkClash/commit/98bf565cd67fb5242ecc5c426b1d227465f4ead4))
* **ui:** 接通日用三页并对齐代理交互 ([c9964e2](https://github.com/VOD-Studio/ArkClash/commit/c9964e2520a66b7d4c8b08cf81565f2b376d4169))


### 修复

* **profiles:** 移除批量刷新和导入的重复计数 ([ee62a1c](https://github.com/VOD-Studio/ArkClash/commit/ee62a1c6847f43ab35778f8ddb083ec5e645fcb0))
* **proxies:** 修复分组过渡与滚动器生命周期 ([e01a987](https://github.com/VOD-Studio/ArkClash/commit/e01a9872d7c2e8bd79a4e58ccc95f8b813a664fc))
* **proxies:** 修正分组折叠与吸顶边界 ([41f3f49](https://github.com/VOD-Studio/ArkClash/commit/41f3f4994170faa491a8736758846fc51e9bf1c5))
* **proxies:** 按 FlClash 对齐分组标题与节点卡样式 ([8463698](https://github.com/VOD-Studio/ArkClash/commit/84636981344e1a456edbf563f9a8ad600578d0e0))
* **proxies:** 补齐节点按压扩散与复用清理 ([9fd35d7](https://github.com/VOD-Studio/ArkClash/commit/9fd35d7518c5972264f167720c252295ee87f6f1))
* **runtime:** 恢复异常终止后的代理启停状态 ([59dfca3](https://github.com/VOD-Studio/ArkClash/commit/59dfca3954da1f486280b7cbffd6c85469db37ec))
* **ui:** 使用不被外层裁剪的原生卡片阴影 ([efc0343](https://github.com/VOD-Studio/ArkClash/commit/efc034399b3dd47480ce571bcc053a3ed9baebd9))
* **ui:** 保留详情抽屉的组件宿主 ([f6d7a40](https://github.com/VOD-Studio/ArkClash/commit/f6d7a40a345d0fc83a7a51fadc35cf639887fc70))
* **ui:** 在首页原位打开配置详情抽屉 ([7823523](https://github.com/VOD-Studio/ArkClash/commit/7823523e1ca770afb5941203cb3bbab029dc2b99))
* **ui:** 将未实现的连接统计标为开发中 ([c4ebb2f](https://github.com/VOD-Studio/ArkClash/commit/c4ebb2f12655656f47bb55043b80da4297f8a791))
* **ui:** 展示最多四项服务状态预览 ([58804d4](https://github.com/VOD-Studio/ArkClash/commit/58804d4997c01f5a1ceb4d724f78d0d90fa9ba8b))
* **ui:** 恢复网络速度图表的实际绘制尺寸 ([cf2d8fe](https://github.com/VOD-Studio/ArkClash/commit/cf2d8fe59bc9f6769da5606b7bbab7b36238dd90))
* **ui:** 按 FlClash 调整页面、卡片与节点卡的底色层级 ([2b7fac5](https://github.com/VOD-Studio/ArkClash/commit/2b7fac513400b812164e2f4c7a8d54a296b35f6c))
* **ui:** 收敛卡片编辑与原生动效状态 ([496e493](https://github.com/VOD-Studio/ArkClash/commit/496e4931312d2cd7445501b7a85c9b24696d2685))
* **ui:** 校正代理组摘要头像的叠放布局 ([5bdeb70](https://github.com/VOD-Studio/ArkClash/commit/5bdeb702b1caddc29fb052be57ff93e3a96dadfd))
* **ui:** 校正配置用量波形的绘制坐标 ([a398331](https://github.com/VOD-Studio/ArkClash/commit/a3983318dc9066a241c0765b286cd3796de8a46d))
* **ui:** 稳定状态卡布局并补齐真实出口信息 ([e19cb95](https://github.com/VOD-Studio/ArkClash/commit/e19cb9599aa9c1bc9d72e6e639279e912c92a5ba))
* **ui:** 精简仪表盘与抽屉的重复说明 ([08ce3b1](https://github.com/VOD-Studio/ArkClash/commit/08ce3b1729c0d43781af7fa4dbe2b0cc2f2df9c7))
* **ui:** 纠正三页布局并保留原生交互组件 ([2111bed](https://github.com/VOD-Studio/ArkClash/commit/2111beda251758c5feba39298ce08fe946deeef8))
* **ui:** 统一三页标题按钮的原生材质 ([127f1a8](https://github.com/VOD-Studio/ArkClash/commit/127f1a8d6fb4e0b02d636e654332756d53c7430c))


### 重构

* **proxies:** 移除页签风格并保留分组列表 ([23c214e](https://github.com/VOD-Studio/ArkClash/commit/23c214eb729b51304eaf000c91eaedbcd072d49a))

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
