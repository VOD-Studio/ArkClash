# 界面范式：抽屉、空状态与动效

以「附加规则」页为样板，整理重构其他页面时可直接沿用的版式、尺寸和动效。数值都取自现有实现，改动时先对照样板代码，再按本页复用。通用约束仍以 [ui.md](ui.md) 为准，本页只补充具体做法。

共用部件（`entry/src/main/ets/components/`）：

| 文件 | 内容 |
|---|---|
| `SheetParts.ets` | 共用部件与动效参数：抽屉标题区 `SheetHeader`、主/次按钮 `PrimaryButton` / `SecondaryButton`、提示卡 `NoteCard`、可选胶囊 `ChoiceChip`，入场与过渡函数 `enterMotion` / `sectionTransition` / `pressEffect` |
| `IllustratedEmpty.ets` | 带插画的空状态 `IllustratedEmpty` 及「无匹配」「读取失败」变体，占位按钮 `EmptyAction`（可在按钮上弹菜单） |

样板代码（`entry/src/main/ets/features/tools/`）：

| 文件 | 内容 |
|---|---|
| `AddedRulesEmpty.ets` | 空状态：提供最前那张卡的内容和操作按钮 |
| `AddedRuleEditor.ets` | 表单抽屉：分组菜单、横滑胶囊、按需出现的区块、内联放弃确认 |
| `AddedRulePresets.ets` | 多选卡片列表抽屉，固定标题与底部按钮 |
| `AddedRuleDeleteSheet.ets` | 删除确认抽屉，带待删内容预览 |
| `AddedRulesPage.ets` | 三个抽屉的 `bindSheet` 选项、快照式打开、脏数据保护 |

## 复用方式

- 共用部件只依赖 `components/`，各 feature 直接 import。`ruleTargetTone`（`features/tools/AddedRuleTone.ets`）这类业务判断留在各自 feature。
- 同一处只保留一份定义，不在新页面里复制一套常量；缺少的通用部件补进 `components/`。

## 抽屉

### 选项

- 一律 `showClose: false`、不传 `title`，标题区由内容自己绘制；`preferType: SheetType.BOTTOM`，材质用 `appStyle.sheetMaterial()`。
- 高度按内容量选：
  - 内容一屏以内（表单、确认）：`SheetSize.FIT_CONTENT`。根节点用不设高度的 `Scroll`，内容超出时自动滚动。
  - 列表超过一屏：`SheetSize.LARGE`，标题区固定在顶部、主按钮固定在底部，中间 `Scroll` 设 `layoutWeight(1)` 并开 `fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(16) })`。`FIT_CONTENT` 下 Column 没有主轴尺寸，`flexShrink` 不生效，做不出固定底栏。
- 含输入框的抽屉设 `keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_RESIZE`：整个抽屉抬到键盘上方并压缩，保存按钮滚动可达。
- 有脏数据时，`onWillDismiss` 不直接关闭，改为在抽屉内显示放弃确认；进行中禁止下滑关闭。标题区的关闭按钮走同一个判断。
- 打开前取一次快照（如预设页的已有规则、删除页的预览），抽屉是模态的，开着时数据不会变。

### 版式

- 内容左右 `PAGE_GUTTER`（16），顶部 20（确认类 24），底部 24；区块间距 12（确认类 14）。
- 标题区（`SheetHeader`）：48 圆角 16 的图标块，底色 `palette.profileExpiryTonal`，图标 24、品牌色；标题 20fp / 行高 26 / 600；可选副标题 13 / 18、次要色、最多两行；右侧关闭按钮复用 `HEADER_ACTION` 与 `headerMaterial()`，图标 `sys.symbol.xmark` 20。标题区与第一个区块相距约 18（确认类 14）。
- 删除类标题区图标块换成 `profile_expiry_error_tonal` 底、`status_error` 图标。

### 卡片与行

- 卡片圆角 `SHEET_CARD_RADIUS`（20），底色 `palette.cardBackground`，`clip(true)`。
- 带图标的行高 72：左侧 40 的圆形图标块（`palette.brandSoft` 底、品牌色图标 20），间距 12；文字区上为 13 / 18 次要色的说明，下为 17 / 24 / 600 的值。分隔线从文字左缘起（`SHEET_TEXT_INSET` = 68），右侧留 16。
- 开关行高 64，同样带图标块；纯说明行可去掉图标块。
- 整行可点的选择行用 `Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL })` 包住，`borderRadius(0)`、`padding(0)`，借系统按压态；右侧放分组名（13 次要色）和 `sys.symbol.chevron_down`（14）。
- 输入行把 `TextInput` 放在说明下方：透明底、`padding(0)`、高 26、光标品牌色；整行 `onClick` 用 `getFocusController().requestFocus(id)` 聚焦，不必瞄准那一行字。占位文字给该字段的真实写法（如 `192.168.0.0/16`），比「请输入…」更能说明格式。

### 选择控件

- 选项多且能分组：在整行上 `bindMenu`，菜单里用 `MenuItemGroup({ header })` 分组，`MenuItem(...).selected(...).selectIcon(true)` 标出当前项。不用样式难调的 `Select`。
- 选项少、需要一眼可见：用横滑胶囊（`ChoiceChip` + 横向 `List`）：
  - 胶囊高 36、圆角 18，左右内边距 12 / 14，前导 7 的语义色圆点或 14 的图标，文字 14；业务标识用等宽 600，普通文字用应用字体 500。
  - 选中只换底色和字色（品牌底、`onBrand` 字），宽度不变，换行或滚动布局不会跳。
  - `List` 横向、高 36、间距 8，`contentStartOffset` / `contentEndOffset` 16 与卡片内边距对齐，`fadingEdge` 20 提示可滑动；`initialIndex` 取当前项前一项，打开时让选中项和半个邻居都在视野里。
  - 语义色：直连类 `status_connected`，拒绝类 `status_error`，跟随品牌的用 `palette.brand`，其余 `font_tertiary`。
- 多选卡片（预设页）：卡片内边距 14 / 16，左侧 44 圆形图标块，右侧 24 的 `circle` / `checkmark_circle_fill`。选中时图标块从 `brandSoft` 变为品牌底反色图标，卡片底从 `cardBackground` 变为 `palette.selectionTonal`。已生效、不可再选的项整卡 `opacity(0.6)`，右侧换成「已添加」胶囊（高 24、圆角 12、`profileExpiryTonal` 底、品牌色 12 / 600）。
- 卡片里的元信息胶囊：高 20、圆角 10、内边距 7，等宽 11 / 600；按语义取 `success_soft` + `success_foreground`、`error_soft` + `status_error` 或 `brandSoft` + 品牌色。

### 操作区

- 主按钮（`PrimaryButton`）：通栏胶囊，高 48，品牌底、`onBrand` 字 16 / 600。没准备好时禁用；进行中按钮里转圈、文字换成「保存中」，保持实色不变灰，只是不响应点击。
- 危险操作用 `danger` 样式：`profile_expiry_error_tonal` 底、`status_error` 字，进行中文字不变。不用整块红底。
- 次按钮（`SecondaryButton`）：`ButtonStyleMode.NORMAL` 胶囊，高 48，文字着色（普通用主色，放弃类用 `status_error`）。
- 「取消 / 确认」并排时 `Row({ space: 10 })` 各占 `layoutWeight(1)`，取消在左。标题区已有关闭按钮的表单不再放「取消」。
- 进行中只锁表单区（各卡片 `enabled(!saving)`），不锁操作区，否则按钮会被一起置灰。

### 提示与确认

- 提示卡（`NoteCard`）：内边距 14、圆角 20，18 的图标 + 14 / 20 文字。错误用 `profile_expiry_error_tonal` 底和 `status_error`；普通提示用卡片底和次要色。
- 不用 Alert。放弃确认放在抽屉内：操作区换成提示卡 +「继续编辑 / 放弃修改」。两套操作叠在同一个 `Stack({ alignContent: Alignment.Bottom })` 里交替出现，切换时不会先把高度撑成两份。
- 删除确认列出将被删除的内容：最多 3 行（类型等宽 14 / 600、内容等宽 12 次要色、右侧策略 13 / 600 语义色），更多的用一行「以及另外 N 条」收尾，抽屉高度不随选择数量增长。

## 空状态

- 根节点 `width('100%')`、`height('100%')`、`justifyContent(Center)`，左右 32、底部多留 96，让视觉重心略高于几何中心。
- 插画用三张叠放的卡片表达「列表」：

  | 卡片 | 宽 × 高 | 上移 | 缩放 | 不透明度 | 内容 |
  |---|---|---|---|---|---|
  | 最前 | 232 × 60 | 0 | 1 | 1 | 34 圆形图标块、两道骨架条、语义色胶囊，阴影 `radius 28 / offsetY 10 / #16000000` |
  | 中间 | 208 × 52 | −30 | 0.95 | 0.82 | 只画卡面，阴影 `12 / 3 / #0A000000` |
  | 最后 | 184 × 46 | −58 | 0.9 | 0.56 | 只画卡面 |

  后两张只露出上沿，里面的内容会被挡掉一半，所以不画。卡片后面铺一层 240 的径向渐变光晕（`brandSoft` → 透明），向下偏 28，压在最前那张卡后面。
- 文字：标题 20 / 26 / 600；说明 14 / 21 次要色，`maxWidth` 300，控制在一行内，不出现单字换行。插画与标题间距 28。
- 操作：间距 12 的两个胶囊按钮，高 44、内边距 18 / 20，图标 18 + 文字 15 / 600。主操作品牌底，次操作 `brandSoft` 底品牌色字。与文字间距 28。
- 变体共用版式，插画换成 72、圆角 24 的图标块（外加 200 的光晕）：搜索无结果用放大镜、不放按钮；读取失败用 `error_soft` 底的警告图标，只放「重试」。

## 动效

所有参数集中在共用部件里，新页面引用常量，不另写数字。

| 用途 | 参数 |
|---|---|
| 区块入场 | `curves.springMotion(0.5, 0.92)`，从下方 16 上浮并淡入，按出现顺序每块延迟 40ms |
| 即时反馈（选中、展开、换色） | `curves.responsiveSpringMotion(0.36, 0.86)` |
| 区块出现 | 不透明度 + 上移 8 + 缩放 0.98，晚 70ms 开始，先让下方内容让出位置 |
| 区块消失 | 只淡出，120ms，`Curve.Sharp` |
| 插画卡片展开 | `curves.springMotion(0.62, 0.8)`，每张延迟 70ms，到位时带一点惯性 |
| 按压 | `clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })` |
| 图标切换 | `SymbolGlyph.symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), trigger)` |

- 入场：组件持有 `entered`，`aboutToAppear` 里设为 `!motion`，根节点 `onAppear` 里设为 `true`；每个区块包一层 `Column`，依次写 `opacity`、`translate`，再 `.animation(enterMotion(motion, index))`。区块随抽屉上滑同时浮现，整体在抽屉停稳前后结束。
- 会因选择而出现或消失的区块，在 `animateTo({ curve: SETTLE_SPRING }, ...)` 里改状态，并给区块加 `.transition(sectionTransition(motion))`；同一位置的两套内容用 `Stack` 叠放交替。
- 颜色过渡只对支持属性动画的属性生效：圆点用带 `backgroundColor` 的 `Row` 画，`Circle.fill` 不参与动画、会跳色。
- 减弱动态：页面把系统设置作为 `motion` 参数传入；关闭时入场首帧即终态（`entered` 初值为 `true`），`enterMotion` 返回零时长，过渡用 `TransitionEffect.IDENTITY`，`clickEffect` 传 `null`，`symbolEffect` 的触发值固定不变。空状态在页面不在前台时也按关闭处理。

## 易错点

- `@Builder` 按值传参不随状态刷新。会变的内容（如随类型切换的图标）直接在调用处读状态，或改成组件参数，不要经 `@Builder` 参数转一手。
- 不能在 `@Builder` 调用后面链式加属性；需要偏移、透明度时，把属性写进 builder 内部或外包一层容器。
- 自定义组件可以直接接 `layoutWeight`、`margin` 等通用属性；需要转场时包一层容器，把 `transition` 挂在容器上。
- 选中态不要改变元素宽度（例如选中才出现对勾），换行布局会整体跳动。
- 文案按最窄的常见屏宽检查换行，出现单字掉行就缩短，不靠缩小字号。

## 验收

- 截图覆盖首屏、每个抽屉、键盘弹起、进行中、错误和放弃确认等状态；颜色、换行和遮挡问题以真机截图为准。
- 中间帧：截图耗时比动画长，抓不到过程。临时把入场和反馈弹簧的 response 与延迟放大约 6 倍，单独打一个慢放包装机截图，看完把源码改回再出正式包；慢放改动不提交。
- 动效还要看快速反向（连续点选、展开又收起）和结束状态，减弱动态下确认没有残留动画。
