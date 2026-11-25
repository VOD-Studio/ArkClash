# Changelog

## 未发布

### 构建

* **toolchain:** 将固定 Go 工具链从 1.26.5 升级到 1.27.4，保留现有 ARM64 与 x86_64 鸿蒙 TLS 补丁。

### 功能

* **ui:** 工具页新增主题设置，支持实时预览、深浅色与纯黑、系统及自定义配色、导航样式与动效、沉浸光感、字体和字号。

* **core:** 打开应用自动预热唯一核心，VPN 转发独立连接/断开；首次系统授权提前，批准不自动接管流量。未连接可选择节点并执行真实 URLTest，普通连断保留配置身份、选择和测速结果；手机驻留及功耗待真机验收。
* **profiles:** 首个配置可激活空核心，迟到激活不能覆盖新选择；删除最后一个配置后保留空核心，运行中的配置操作继续走 controller。
* **tools:** 最近请求与 DNS 查询在应用存活时持续记录，离页或退到后台不再漏掉记录。重新打开页面读取最近 2,000 条请求与 3,000 条 DNS 查询，不落盘。
* **geodata:** 新增四类 Geo 资源页，支持本地信息、单项/全部更新、URL 编辑/恢复/复制和自动更新间隔；仅就绪内核下载，串行可取消并安全热生效，安装包升级不覆盖已接管数据。
* **toolchain:** 支持显式选择 x86_64 内核与 HAP，新增模拟器动态加载及多线程 C API 冒烟；默认 ARM64 不变，应用/VPN 验收待签名后完成。

### 修复

* **runtime:** 修复部分鸿蒙固件回收 VPN 授权观察者时导致的 UI 进程闪退；改用系统启动 Promise 处理授权结果。
* **runtime:** 用持久化意图/token 与统一队列隔离迟到 VPN 操作，分别记录系统 VPN、Go TUN 和业务入口，清理失败不伪造停止。
* **core:** 平台与 Go 分别持有原始/复制的 TUN fd；修复构造回滚与重复关闭风险，完整关闭同步退休 DNS、controller 及 hijacked WebSocket。
* **core:** 断开或热切换时取消尚未建立的转发拨号，关闭未完成握手的 TCP 连接并等待旧转发退出；普通断开不打断独立测速。
* **ui:** 代理节点的协议与延迟统一在同一行左右对齐，宽松卡片同步收紧高度，保留独立测速操作。
* **ui:** Geo 资源页恢复系统安全区避让，修复标题、返回及顶部操作按钮与状态栏重叠、点击区域被截断。
* **ui:** Resources 页顶部刷新按钮随原生标题栏高度居中并保留右侧留白，修复圆形边框贴边裁切及与返回按钮错位。
* **ui:** Connections 与 DNS 查询页顶部操作随原生标题栏居中并保留右侧 16vp 留白；诊断底部选择菜单保证至少 56vp 的点击区。
* **ui:** 工具页将连接、DNS 查询和资源归为一组，移除日志和设置的占位入口，保留单独的关于入口。
* **ui:** 连接页「更多」改为锚定按钮的弹出菜单，协议与规则可连续多选；规则筛选按类型合并不同匹配值，分组标记当前选项并默认折叠，无域名时按目标 IP 分组。不新增应用归属或 MITM 采集。
* **ui:** 连接记录按 ID 增量刷新，流量和时长原地更新；连接增删和排名换位用原生过渡，遵循系统减弱动态设置。
* **ui:** 连接和最近请求详情按 FlClash v0.9.3 分为基础信息、地址和代理，支持点按整行复制，代理链按经过顺序显示为可换行标签。
* **ui:** DNS 查询复用连接记录的原生列表过渡；首条结果到来时空态淡出，暂停跟随时新查询不打断当前阅读。
* **ui:** Geo URL 与更新间隔编辑弹窗改为顶部对齐，键盘弹出时压缩滚动区域，避免遮挡恢复默认、取消和保存操作。
* **ui:** Geo 资源页正文从标题栏下方顶部对齐，内容不足一屏时不再垂直居中。
* **core:** Geo MMDB/ASN reader 以原子指针切换，旧查询保持 reader 生命周期；初始化下载错误不再包含来源 URL。
* **tests:** 宿主回归自动准备 OHPM 依赖和编译器，按固定 Go 版本分离内核编译与执行时限，修复探测取消用例的旧接口和依赖加载。
* **profiles:** 显式保留批量任务返回的 Promise 类型，修复静态检查误报，保持对象字面量任务接口和四路并发行为。
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
* **ui:** 分组标题整行可展开和收起，定位、测速及禁用工具区域保持独立命中，不再穿透折叠。
* **ui:** 分组标题的原生按压反馈统一为内缩 4vp 的完整圆角形状，展开状态不再出现方形底边，留白仍可点击。
* **ui:** 修正代理分组工具容器的触摸测试模式，恢复定位和测速子按钮的独立点击。
* **ui:** 仪表盘标题直接切换编辑文字，卡片使用独立属性动画轻动，并在退出编辑、页面隐藏或减弱动态时回正。
* **ui:** 状态卡启停按钮改为高对比拨片轮廓和实心图标，保留按压与旋转反馈；忙碌图形淡出后再停，快速反向时隔离旧完成回调。
* **ui:** 编辑配置的未保存退出和自动更新选择改用原生底部操作面板，取消不丢草稿，保存失败继续编辑，真正保存成功后仅提示一次。
* **ui:** 配置卡恢复原生按压反馈，长按菜单使用标准子菜单 Builder 和 Symbol 图标，修复更新与详情文字重叠并隔离长按后的卡片点击。
* **ui:** 配置应用结果改为去重的原生轻提示，移除顶开列表的常驻说明，明确区分已选择与实际运行的配置。
* **ui:** 删除配置改用原生底部确认面板，执行中阻止重复删除，取消、返回与下拉关闭不修改配置。
* **ui:** 代理页的测速、切换和保存错误改为一次性提示，刷新与保存重试移入原生菜单，不再插入提示条挤动列表。
* **ui:** 配置导入、排序、编辑和校验错误改为原生轻提示，失败保留输入，批量结果单独展示，不再挤压表单。
* **ui:** 首页保存、模式切换和出口检测不再插入警告文字；草稿重试与放弃移入原生底部面板，真实检测状态保留在已有信息栏。
* **ui:** 运行拨片恢复主题配色，启停使用连续弹性旋转与按压形变；背景随启停意图旋转变色，取消启动时直接反向过渡，图标不再叠加替换闪动。
* **ui:** 运行中与质量优标签共用正向文字和柔和背景色，移除独占的亮绿底色，风险标签统一使用错误色。
* **ui:** 首页自动检测前四项服务，打开抽屉补测其余服务并复用一分钟内的结果；离页或收起抽屉取消无关请求，切换出口重测，不增加后台轮询。
* **ui:** 服务抽屉改为连续列表与紧凑原生操作栏，移除大按钮、重复卡片和全局出口信息；状态使用固定位置，服务管理保留显隐、排序与首页展示标记。
* **ui:** 服务显隐更新后重新绑定对应管理行，避免开关继续读取旧状态，关闭服务后仍可重新启用。
* **ui:** 配置排序按当前顺序更新首尾圆角，拖动行保留完整圆角与原生落位反馈，修正分割线溢出和标题下方的过大留白。
* **ui:** 代理失败提示按独立操作区分，相同的定位或测速失败再次发生时仍会提示，同一批测速结果不逐帧重复弹出。
* **ui:** 配置批量更新在后台失败时保留结果，返回页面后单项失败提示一次，多项失败打开结果明细，不再丢失失败列表。
* **ui:** 配置编辑器跟随真实前台和面板可见状态消费失败提示；后台失败保留草稿，返回后提示一次，不把组件尚未销毁误当作正在显示。
* **client:** 出口与服务检测共用四个请求名额，旧请求结束后再调度新出口；取消未发出的排队任务，避免启动和切换时相互挤占并长期显示检测繁忙。
* **ui:** 运行拨片通过原生内容修饰器保留禁用语义而不额外变淡；齿轮改为不占布局的实时图形，修复自定义背景快照不随启停刷新。
* **ui:** 连接与断开过程中拨片、背景齿轮持续原生旋转，结束后明确终止循环、恢复静态姿态；仅连接成功后切换齿轮运行色，页面隐藏或减弱动态时停止循环。
* **ui:** 添加配置改用原生底部选择抽屉，收起后再打开文件选择或订阅表单，避免居中菜单和后续面板叠加。
* **home:** 服务检测移植 FlClash 的 13 项专用协议：Claude trace 地区判定、ChatGPT 多步响应校验及流媒体握手，不再统一 HEAD 首页；保留真实受限、地区与失败结果，未知服务的 405 显示方法不支持。
* **client:** 规则探测支持目标请求头、POST、重定向和有界正文扫描；运行与停止时共用判据，保留实际并发限制、取消和跨代结果隔离，修复大网页被误判检测失败。
* **ui:** 代理页只保留分组列表，移除风格切换和旧页签偏好分支；保留排序、布局、尺寸和图标设置，以及首页节点选择器的分组切换。
* **ui:** 代理节点增加触点扩散与松开淡出，拖动时取消反馈，复用时清理旧按压状态；保持浅色卡片、独立选中标记与测速操作，分组标题继续使用原生按压。
* **ui:** 精简仪表盘和抽屉中的重复说明，保留可操作的失败反馈和真实数据状态。
* **ui:** 保留服务品牌图标原色并补齐 ChatGPT，将 AI 集中排列在 Google 后，保留已有显隐设置。
* **ui:** 区分主动滚动与弹簧回弹，避免快速滑动后底部栏误恢复。
* **ui:** 按固定 FlClash v0.9.3 与 Prism 源码调整仪表盘、代理和配置页的布局、卡片、字体及操作入口，保留原生浮动栏图标、出站模式切换组件、模糊和沉浸光感。
* **ui:** 配置失败结果逐行懒加载，为重复无效输入保留独立行，避免批量失败时漏行。

### 性能

* **ui:** 使用系统异步接口采集界面进程内存，避免在 ArkTS 主线程同步读取 smaps。

## [0.6.2](https://github.com/VOD-Studio/ArkClash/compare/v0.6.1...v0.6.2) (2026-11-25)


### 新增

* animate appearance mode transitions ([59a6257](https://github.com/VOD-Studio/ArkClash/commit/59a6257fe6b9a0f97a80df2149f1f180c99de085))
* **editor:** 补全 Tailscale 出站配置 ([28fbc31](https://github.com/VOD-Studio/ArkClash/commit/28fbc319c287814ff83ca75a363ba7358b3fe9dc))
* **profiles:** 节点改名时更新 Tailscale DNS 引用 ([aa4f6fb](https://github.com/VOD-Studio/ArkClash/commit/aa4f6fb03b00753749ebf85bbb1e78c3b3ee451e))
* **profiles:** 补齐订阅卡片一级菜单图标 ([3295e2d](https://github.com/VOD-Studio/ArkClash/commit/3295e2d8fcef8870719ed9246c56e5e2216612cb))
* **proxies:** 支持 Tailscale 节点浏览器登录 ([e908e9d](https://github.com/VOD-Studio/ArkClash/commit/e908e9dc7536b2175b7b6c8aedca2e442d6279d1))
* **tools:** 为最近请求的更多菜单添加分层动效 ([0691968](https://github.com/VOD-Studio/ArkClash/commit/069196898a726635a948d22ad2f612e3820b2325))
* **tools:** 重设计 DNS 查询多选筛选面板 ([e302259](https://github.com/VOD-Studio/ArkClash/commit/e302259da0f2ca664aa43d42f5150b00542452cc))
* 完善 Tailscale 代理体验并修复 0.6.2 交互缺陷 ([#118](https://github.com/VOD-Studio/ArkClash/issues/118)) ([1fed9f7](https://github.com/VOD-Studio/ArkClash/commit/1fed9f77a16443336f93974e7aaa779e13978e89))


### 修复

* **core:** 按转发状态选择订阅下载出口 ([a9f9757](https://github.com/VOD-Studio/ArkClash/commit/a9f9757c5d7cd534fb0efce5c0b7c2c5c108f00d))
* **core:** 支持请求指定内置拨号期限 ([5e39617](https://github.com/VOD-Studio/ArkClash/commit/5e39617431c3acfab279d30813a737e0fe07e2cc))
* **core:** 跨 tailnet 切换时保留真实目标 IP ([486d533](https://github.com/VOD-Studio/ArkClash/commit/486d53319e3a1965405cdb088279f30999590d9f))
* **core:** 通过鸿蒙默认网络启动 Tailscale 出站 ([1f34972](https://github.com/VOD-Studio/ArkClash/commit/1f34972445abd5f304ef37cef4e51fc26f837ec6))
* **tools:** 为主题入口使用调色盘图标 ([5234c6c](https://github.com/VOD-Studio/ArkClash/commit/5234c6c1a831689e666347a93f66ef780c7725eb))
* **tools:** 为常规设置操作补充行内加载状态 ([b49da16](https://github.com/VOD-Studio/ArkClash/commit/b49da163dd6032739c104c369cf6da3f8b2818dc))
* **tools:** 修复连接和 DNS 查询页面的过滤标签显示问题 ([3fb77f6](https://github.com/VOD-Studio/ArkClash/commit/3fb77f6efe50edee5598455be9ca70fccc35e954))
* **tools:** 消除更多菜单切层时的文字重影 ([d0f12d7](https://github.com/VOD-Studio/ArkClash/commit/d0f12d751ace979e25dd07905fe81b08520ee02b))
* **tools:** 重构 DNS 添加覆写项面板并修复无法滚动问题 ([0efc5ae](https://github.com/VOD-Studio/ArkClash/commit/0efc5ae141959e5944c381256a2c7dbbc6da106a))
* **ui:** 修复附加规则等页面顶部操作按钮不响应状态更新 ([54752b1](https://github.com/VOD-Studio/ArkClash/commit/54752b1b4cccdad58182079630aba505fbc0e01f))
* **ui:** 正确提示订阅下载超时 ([f797501](https://github.com/VOD-Studio/ArkClash/commit/f79750127b7fcd6f9294f04bd4d6c6a43eab7648))
* **ui:** 消除主题选项保存时的闪烁 ([b05a5fc](https://github.com/VOD-Studio/ArkClash/commit/b05a5fc7684db83fc6c07c2e9ca924a7d1e4dbae))
* **ui:** 消除新建脚本界面的白屏和布局闪烁 ([e2f307b](https://github.com/VOD-Studio/ArkClash/commit/e2f307b8727d3e5d6852f897a99323b2491f8fb3))
* **ui:** 统一主题字体选择器的排版 ([2f900d9](https://github.com/VOD-Studio/ArkClash/commit/2f900d97849f0123bffedb04b96c5420dbb7cae2))
* **ui:** 统一滚动页面的沉浸式标题栏 ([0f5ba48](https://github.com/VOD-Studio/ArkClash/commit/0f5ba4896a1ba53d0f271b83117d2745df015c49))
* **ui:** 让标题栏毛玻璃从首屏生效 ([dacb5ef](https://github.com/VOD-Studio/ArkClash/commit/dacb5ef4afc34214df41b26e39ed499be710ee94))
* **ui:** 让页面转场覆盖状态栏区域 ([c717f33](https://github.com/VOD-Studio/ArkClash/commit/c717f33c1f130d9c7cf0e1f1f9113aa5f5247b16))
* **ui:** 防止主题字号滑块松手时回跳 ([eb38107](https://github.com/VOD-Studio/ArkClash/commit/eb381075ae291bbe2da04d84c756f9fc1a84d7c9))


### 性能

* **core:** 常规请求与内核设置改为原地热更新 ([80db976](https://github.com/VOD-Studio/ArkClash/commit/80db976ca8bc442c58628dfbfad24a6c8616e065))

## [0.6.1](https://github.com/VOD-Studio/ArkClash/compare/v0.6.0...v0.6.1) (2026-11-24)


### 新增

* 扩展代理配置和连接诊断 ([#110](https://github.com/VOD-Studio/ArkClash/issues/110)) ([3da3fc2](https://github.com/VOD-Studio/ArkClash/commit/3da3fc2ce1f0ceb4d3fe1846d926ea136754ed83))

## [0.6.0](https://github.com/VOD-Studio/ArkClash/compare/v0.5.1...v0.6.0) (2026-11-21)

本版本围绕**配置管理、代理工具箱、网络诊断与个性化设置**进行了全面升级，并支持在未开启 VPN 的状态下直接切换节点与测速。

### 新功能

#### 配置与订阅
- **扫码与唤起导入**：支持通过相机扫码、相册识图、浏览器一键导入（`clash://` / `flclash://`）以及单节点分享链接添加配置。
- **订阅分享与加密支持**：支持将现有订阅生成二维码分享，并支持导入和自动更新 `age` 加密订阅。
- **内置代码编辑器与配置预览**：提供带 YAML 语法高亮与自动补全的离线编辑器，支持结构化编辑自定义配置，并可随时查看合并覆写后的最终生效配置。
- **全局覆写与脚本扩展**：支持全局 DNS 覆写、自定义附加分流规则，以及通过 JavaScript 脚本对订阅配置进行预处理。

#### 节点与资源管理
- **未连接状态下预热测速**：打开应用即可查看节点列表、切换代理并执行真实延迟测速，无需先开启 VPN 连接。
- **本地节点库与代理工具**：支持集中维护自定义节点（或从节点卡片一键存入本地库），并提供正则筛选预设与代理组图标集管理。
- **Geo 与 Provider 资源管理**：新增 GeoIP / GeoSite / MMDB / ASN 数据库管理（支持进度显示、自定义下载源与自动更新），并支持在资源页查看、刷新运行中的代理集合（Proxy Providers）与规则集合（Rule Providers）。

#### 诊断、设置与备份
- **连接、DNS 与日志诊断**：新增实时连接、最近请求、DNS 查询记录与运行日志页面，支持按协议或规则类型筛选连接、查看完整代理链并一键复制详情。
- **VPN 与通用设置**：支持配置分应用代理（应用绕过）、TUN 网络参数（协议栈、MTU、IPv6、DNS 劫持）、入站监听端口、局域网认证、外部控制器、自定义 `User-Agent`、自定义 Hosts 及测速超时。
- **外观与主题定制**：新增主题设置，支持深浅色模式、纯黑背景、系统及自定义主题色、沉浸光感效果、导航动效与字号调整，并提供实时预览。
- **备份与恢复**：支持将配置文件或全部应用设置导出为本地 ZIP 备份包，或通过 WebDAV 进行云端备份与恢复。
- **应用内更新与模拟器支持**：仪表盘支持检查应用更新并下载安装包；新增 `x86_64` 架构支持，可在 HarmonyOS 模拟器上原生运行。

### 优化与修复

- **连接稳定性提升**：优化 VPN 启动与断开流程，修复部分机型在授权弹窗关闭后偶发的闪退问题，切换配置或断开时更彻底地清理残留连接。
- **配置与状态同步**：修复 HTTP Upgrade 节点分享链接参数解析异常；修复备份恢复后外部控制器状态未即时同步、修改 `User-Agent` 后需重载才生效的问题。
- **界面交互打磨**：消除仪表盘内网 IP 卡片闪烁，统一加载骨架屏与底部操作弹窗样式，优化代理列表定位滚动、节点卡片排版及键盘弹出时的避让体验。

## [0.5.1](https://github.com/VOD-Studio/ArkClash/compare/v0.5.0...v0.5.1) (2026-11-15)


### 修复

* **client:** 限制跨代出口与服务检测的实际并发 ([a124d80](https://github.com/VOD-Studio/ArkClash/commit/a124d8085b1cd3ba9cd9728db80ccb62e57194df))
* **home:** 仅在启停处理中旋转拨片与背景 ([cf425a1](https://github.com/VOD-Studio/ArkClash/commit/cf425a1a62d69105959751a25ee98aff29b19a64))
* **home:** 修复启停按钮变淡与背景快照停滞 ([d3349fa](https://github.com/VOD-Studio/ArkClash/commit/d3349fad6005a8b65ff3da9236728bcf6b61c57a))
* **home:** 分离编辑标题与卡片动效事务 ([2d472fe](https://github.com/VOD-Studio/ArkClash/commit/2d472fe7888e46363cc128d9b47e14d546d2de0c)), closes [#90](https://github.com/VOD-Studio/ArkClash/issues/90)
* **home:** 对齐运行拨片的主题与启停动效 ([8701631](https://github.com/VOD-Studio/ArkClash/commit/8701631d68fb3669d284a357bfa8b14f2bed7038))
* **home:** 将操作反馈移出卡片布局 ([3c3efa6](https://github.com/VOD-Studio/ArkClash/commit/3c3efa6ca1b287d0c3dc846f8786e2019b67ab5e))
* **home:** 按 FlClash 协议检测服务可用性 ([d202a18](https://github.com/VOD-Studio/ArkClash/commit/d202a18300cf1f661d6c316c430d73fb3448739b))
* **home:** 改用连续反馈的拨片运行按钮 ([cffbbf3](https://github.com/VOD-Studio/ArkClash/commit/cffbbf3cd12cddbef20399083f6daf7ab57501fa)), closes [#90](https://github.com/VOD-Studio/ArkClash/issues/90)
* **home:** 更新服务显隐后的管理行绑定 ([e2a9a3a](https://github.com/VOD-Studio/ArkClash/commit/e2a9a3afff3a9a63b27781d02b6a5deff8f6a29f))
* **home:** 精简服务状态抽屉布局 ([15cf035](https://github.com/VOD-Studio/ArkClash/commit/15cf03587b26d3d22b5f2d2a3c0d0a2e64b7d1c4))
* **home:** 统一正向状态标签配色 ([b94fbbb](https://github.com/VOD-Studio/ArkClash/commit/b94fbbb300337396849ad8f5d3cb6bc282c3a55e))
* **home:** 自动检测可见服务并取消离页请求 ([fba7fe4](https://github.com/VOD-Studio/ArkClash/commit/fba7fe4ea89c43275109edf910eab91fba4b3aea))
* **profiles:** 使用底部选择抽屉添加配置 ([c9fd995](https://github.com/VOD-Studio/ArkClash/commit/c9fd9950fa974239620646b971e35175ec447e08))
* **profiles:** 保留后台完成的批量失败结果 ([5986f43](https://github.com/VOD-Studio/ArkClash/commit/5986f4364bfe01524b24cf9846d5e78d641c3d01))
* **profiles:** 修复原生菜单结构和卡片按压 ([5b5cdd1](https://github.com/VOD-Studio/ArkClash/commit/5b5cdd1ac7b91796b6e202eb4bf3e194f4379b60))
* **profiles:** 修正排序行圆角与拖动反馈 ([15a1a06](https://github.com/VOD-Studio/ArkClash/commit/15a1a0632c6e600bfff4c252f30008a338af8e42))
* **profiles:** 将应用结果移出列表布局 ([1de974b](https://github.com/VOD-Studio/ArkClash/commit/1de974b970c2306a2e46b08dcf184469367ef138))
* **profiles:** 将表单操作反馈改为原生轻提示 ([a326697](https://github.com/VOD-Studio/ArkClash/commit/a326697a9fcee45c0a80ea506da843c2f5a6cea7))
* **profiles:** 延迟消费后台编辑失败提示 ([f71ca2c](https://github.com/VOD-Studio/ArkClash/commit/f71ca2c2464218ac94802745210eff1e708ff621))
* **profiles:** 改用底部面板确认删除 ([f4305b5](https://github.com/VOD-Studio/ArkClash/commit/f4305b5bd1f5114b6a9eef7be5e33a4dba16d3f0))
* **profiles:** 用原生底部面板保护编辑退出 ([8c66f54](https://github.com/VOD-Studio/ArkClash/commit/8c66f54b5288f68c036f43431b062730a72d6fba))
* **proxies:** 保留折叠期间的分组标题实例 ([c1e7985](https://github.com/VOD-Studio/ArkClash/commit/c1e798546b8b6bb2446328e82efbd693cc284354)), closes [#89](https://github.com/VOD-Studio/ArkClash/issues/89)
* **proxies:** 内缩分组标题的原生按压反馈 ([95e7a99](https://github.com/VOD-Studio/ArkClash/commit/95e7a997a3d923b141b751433ffe0f4a2e2d6934))
* **proxies:** 将操作反馈移出列表布局 ([cea9987](https://github.com/VOD-Studio/ArkClash/commit/cea998703477283284ea0ae1e9bcb426f86d5110))
* **proxies:** 恢复分组工具的子按钮命中 ([4e4756a](https://github.com/VOD-Studio/ArkClash/commit/4e4756ae0658931e3c329ecfad838e114811a45a))
* **proxies:** 扩展分组标题的整行点击热区 ([d49d953](https://github.com/VOD-Studio/ArkClash/commit/d49d9530326d90742acf9c359e0329d6b3c552de)), closes [#89](https://github.com/VOD-Studio/ArkClash/issues/89)
* **proxies:** 按独立操作触发失败轻提示 ([30e1437](https://github.com/VOD-Studio/ArkClash/commit/30e1437dd8c66b603d229181af194b1df2d5e7ea))
* 修复日用界面交互与服务检测回归 ([b97c113](https://github.com/VOD-Studio/ArkClash/commit/b97c113d199fa1d8ec4200e9451b7586a9edb419))

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
