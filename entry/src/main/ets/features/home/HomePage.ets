import { common } from '@kit.AbilityKit';
import { CapsuleSegmentButtonV2, SegmentButtonV2Items, uiMaterial } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { connection, Connection, ConnectionState } from '../../client/Connection';
import { getMainGroup, getMode, GroupSummary, OutboundMode } from '../../client/Controller';
import { ExitIp, flagOf, lookupExitIp } from '../../client/ExitIp';
import { HISTORY_SIZE, traffic, Traffic } from '../../client/Traffic';
import { EmptyState } from '../../components/EmptyState';
import { LabeledValue, Tag } from '../../components/Labels';
import { formatBytes, splitBytes } from '../../components/Format';
import { SpeedChart } from '../../components/SpeedChart';
import { TabPage } from '../../components/TabPage';
import { CARD } from '../../components/Theme';

const MODES: OutboundMode[] = ['rule', 'global', 'direct'];
const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;
// 订阅提醒的阈值：剩余流量低于这个比例，或者离到期不到这么多天。
const LOW_USAGE_RATIO = 0.1;
const EXPIRY_WARN_DAYS = 3;
// 延迟分档，和代理页一致。
const DELAY_GOOD_MS = 300;
const DELAY_SLOW_MS = 800;

enum ExitIpState {
  Idle,
  Loading,
  Ready,
  Unavailable
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function formatUptime(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${pad2(Math.floor(s / 3600))}:${pad2(Math.floor(s / 60) % 60)}:${pad2(s % 60)}`;
}

function formatSeconds(ms: number): string {
  return (ms / 1000).toFixed(ms < 10000 ? 2 : 1);
}

// 出口地址默认打码，只露首尾两段，点一下才显示完整地址。
function maskIp(ip: string): string {
  const sep = ip.includes(':') ? ':' : '.';
  const parts = ip.split(sep);
  if (parts.length < 3) {
    return ip;
  }
  return [parts[0], '*', '*', parts[parts.length - 1]].join(sep);
}

@ComponentV2
export struct HomePage {
  @Param @Require scroller: Scroller;
  @Param topInset: number = 0;
  // 当前配置的摘要由页面层从配置功能里取来，首页不直接依赖它。
  @Param profileReady: boolean = false;
  @Param profileName: string = '';
  @Param profileUpdatedAt: number = 0;
  @Param profileUpdating: boolean = false;
  @Param usedBytes: number = 0;
  @Param totalBytes: number = 0;
  @Param expireAt: number = 0; // 秒级时间戳，0 = 未知
  // 首页所在的页签在前台且应用可见；不可见时停掉计时。流量推送由页面层统一订阅。
  @Param visible: boolean = false;
  @Event onAddProfile: () => void = () => {};
  @Event onOpenProfiles: () => void = () => {};
  @Event onUpdateProfile: () => void = () => {};
  @Event onOpenProxies: () => void = () => {};
  @Local conn: Connection = connection;
  @Local stats: Traffic = traffic;
  @Local now: number = Date.now();
  @Local exitIp: ExitIp | undefined = undefined;
  @Local exitIpState: ExitIpState = ExitIpState.Idle;
  @Local exitViaProxy: boolean = false; // 当前 exitIp 是经代理查到的还是本机直连的
  @Local revealIp: boolean = false;
  @Local group: GroupSummary | undefined = undefined;
  @Local modeIndex: number = 0;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private ticker: number = -1;
  private modeItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.mode_rule'), symbol: $r('sys.symbol.list_bullet') },
    { text: $r('app.string.mode_global'), symbol: $r('sys.symbol.paperplane') },
    { text: $r('app.string.mode_direct'), symbol: $r('sys.symbol.arrow_right') }
  ]);

  aboutToAppear(): void {
    this.modeIndex = Math.max(0, MODES.indexOf(this.conn.mode as OutboundMode));
    this.sync();
  }

  aboutToDisappear(): void {
    this.stopTicker();
  }

  @Monitor('modeIndex')
  onModeIndexChange(): void {
    const mode = MODES[this.modeIndex];
    if (mode !== this.conn.mode) {
      this.conn.changeMode(mode);
    }
  }

  @Monitor('visible', 'conn.state')
  sync(): void {
    if (this.visible) {
      // 未连接时也要走时，「更新于 N 分钟前」才会变。
      this.startTicker();
    } else {
      this.stopTicker();
    }
    if (!this.conn.connected) {
      this.group = undefined;
    }
    if (!this.visible || this.conn.busy) {
      return;
    }
    if (this.conn.connected) {
      this.refreshCoreInfo();
    }
    // 未连接时显示本机直连的出口，连上后换成代理出口；位置和样式不变，卡片不跳。
    if (this.exitIpState === ExitIpState.Idle || this.exitViaProxy !== this.conn.connected) {
      this.loadExitIp();
    }
  }

  build() {
    TabPage({ title: $r('app.string.tab_home'), topInset: this.topInset, scroller: this.scroller }) {
      if (this.profileReady) {
        this.StatusCard()
        this.SpeedCard()
        this.ModeCard()
        this.ProfileCard()
        this.GroupCard()
      } else {
        Column() {
          EmptyState({
            icon: $r('sys.symbol.doc_text'),
            title: $r('app.string.home_no_profile'),
            hint: $r('app.string.home_no_profile_hint'),
            actionLabel: $r('app.string.action_add_subscription'),
            onAction: () => this.onAddProfile()
          })
        }
        .attributeModifier(CARD)
      }
    }
  }

  // ---- 公共小部件 ----

  @Builder
  CardHeader(icon: Resource, title: Resource, chevron: boolean) {
    Row({ space: 8 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([$r('sys.color.font_secondary')])
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      if (chevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('sys.color.font_tertiary')])
      }
    }
    .width('100%')
    .height(24)
    .margin({ bottom: 14 })
  }

  // ---- ① 状态 ----
  // 连接与否都是同一个骨架：标题和状态标签 / 出口地址和标签行 / 三项数据。只换内容不换排版，卡片不跳。

  @Builder
  StatusCard() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.checkmark_shield'))
          .fontSize(18)
          .fontColor([$r('sys.color.font_secondary')])
        Text($r('app.string.card_status'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        this.StatusChip()
      }
      .width('100%')
      .height(24)
      .margin({ bottom: 14 })

      this.ExitIpRow()

      Row() {
        LabeledValue({
          label: $r('app.string.uptime_label'),
          value: this.conn.connected && this.conn.connectedAt > 0 ? formatUptime(this.now - this.conn.connectedAt) : '—'
        })
          .layoutWeight(1)
        LabeledValue({
          label: $r('app.string.connect_time_label'),
          value: this.conn.connectDuration > 0 ? $r('app.string.seconds_value', formatSeconds(this.conn.connectDuration)) : '—'
        })
          .layoutWeight(1)
        LabeledValue({
          label: $r('app.string.region_label'),
          value: this.regionName()
        })
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }

  @Builder
  StatusChip() {
    if (this.conn.connected) {
      Tag({
        text: $r('app.string.chip_running'),
        color: $r('app.color.status_connected'),
        tint: $r('app.color.success_soft'),
        dot: true
      })
    } else if (this.conn.busy) {
      Tag({ text: this.conn.state === ConnectionState.Connecting ? $r('app.string.status_connecting') :
        $r('app.string.status_disconnecting'), color: $r('app.color.brand'), tint: $r('app.color.brand_soft'), dot: true })
    } else {
      Tag({
        text: $r('app.string.status_disconnected'),
        color: $r('app.color.status_idle'),
        tint: $r('app.color.idle_soft'),
        dot: true
      })
    }
  }

  // 地区旗标 + 大号出口地址 + 一行标签。点地址切换打码。
  @Builder
  ExitIpRow() {
    Row({ space: 12 }) {
      Stack() {
        Text(this.regionBadge())
          .fontSize(this.hasFlag() ? 26 : 15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
      }
      .width(52)
      .height(52)
      .borderRadius(14)
      .backgroundColor($r('app.color.tile_background'))

      Column({ space: 6 }) {
        Text(this.exitAddress())
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .fontFeature('"tnum" on')
          .maxLines(1)
          .minFontSize(16)
          .maxFontSize(24)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .height(30)
        this.TagLine()
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .onClick(() => {
      if (this.exitIpState === ExitIpState.Ready) {
        this.revealIp = !this.revealIp;
      } else if (this.exitIpState === ExitIpState.Unavailable) {
        this.loadExitIp();
      }
    })
  }

  // 固定一行高：连接出错、出口查不到时在这里提示，不另起一行。
  @Builder
  TagLine() {
    Row({ space: 6 }) {
      if (this.conn.error !== '') {
        Tag({
          text: this.conn.error,
          color: $r('app.color.status_error'),
          tint: $r('app.color.warning_soft'),
          dot: false
        })
      } else if (this.conn.connected && this.exitIpState === ExitIpState.Unavailable) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(12)
            .fontColor([$r('app.color.warning')])
          Text($r('app.string.exit_ip_warning'))
            .fontSize(12)
            .fontColor($r('app.color.warning'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(12)
            .fontColor([$r('app.color.warning')])
        }
        .height(22)
        .padding({ left: 8, right: 6 })
        .borderRadius(11)
        .backgroundColor($r('app.color.warning_soft'))
        .onClick(() => this.onOpenProxies())
      } else {
        if (!this.conn.connected) {
          Tag({
            text: $r('app.string.exit_local'),
            color: $r('sys.color.font_secondary'),
            tint: $r('app.color.tile_background'),
            dot: false
          })
        }
        if (this.exitOrg() !== '') {
          Tag({
            text: this.exitOrg(),
            color: $r('sys.color.font_secondary'),
            tint: $r('app.color.tile_background'),
            dot: false
          })
            .flexShrink(1)
        }
      }
    }
    .width('100%')
    .height(22)
  }

  // ---- ② 网络速度 ----

  @Builder
  SpeedCard() {
    Column() {
      this.CardHeader($r('sys.symbol.gauge_with_dots_needle_33percent'), $r('app.string.card_speed'), false)
      Row({ space: 10 }) {
        this.RateTile(true)
        this.RateTile(false)
      }
      .width('100%')
      SpeedChart({
        up: this.stats.upHistory,
        down: this.stats.downHistory,
        capacity: HISTORY_SIZE,
        chartHeight: 56
      })
        .margin({ top: 14 })
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }

  @Builder
  RateTile(upload: boolean) {
    Column({ space: 4 }) {
      Row({ space: 4 }) {
        SymbolGlyph(upload ? $r('sys.symbol.arrow_up') : $r('sys.symbol.arrow_down'))
          .fontSize(14)
          .fontColor([upload ? $r('app.color.upload') : $r('app.color.download')])
        Text(upload ? $r('app.string.traffic_upload') : $r('app.string.traffic_download'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      Row({ space: 3 }) {
        Text(this.rateValue(upload))
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .fontFeature('"tnum" on')
        Text(this.rateUnit(upload))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .margin({ bottom: 4 })
      }
      .alignItems(VerticalAlign.Bottom)
      Text($r('app.string.traffic_total', this.totalText(upload)))
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .fontFeature('"tnum" on')
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(12)
    .backgroundColor($r('app.color.tile_background'))
    .layoutWeight(1)
  }

  // ---- ③ 出站模式 ----

  @Builder
  ModeCard() {
    Column() {
      this.CardHeader($r('sys.symbol.route'), $r('app.string.card_mode'), false)
      // 官方写法：!! 双向绑定选中项；背板加系统材质后，选中块按 HarmonyOS 7 的光感动效滑过去。
      CapsuleSegmentButtonV2({
        items: this.modeItems,
        selectedIndex: this.modeIndex!!,
        enableStateAnimation: true,
        backgroundSystemMaterial: new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR })
      })
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }

  // ---- ④ 配置 ----

  @Builder
  ProfileCard() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.doc_text'))
          .fontSize(18)
          .fontColor([$r('sys.color.font_secondary')])
        Text($r('app.string.card_profile'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          if (this.profileUpdating) {
            LoadingProgress()
              .width(18)
              .height(18)
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(16)
              .fontColor([$r('sys.color.font_secondary')])
          }
        }
        .width(28)
        .height(28)
        .backgroundColor($r('app.color.tile_background'))
        .enabled(!this.profileUpdating)
        .onClick(() => this.onUpdateProfile())
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('sys.color.font_tertiary')])
      }
      .width('100%')
      .height(28)
      .margin({ bottom: 12 })

      Text(this.profileName)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Row() {
        Text($r('app.string.updated_ago', this.relativeTime(this.profileUpdatedAt)))
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
          .layoutWeight(1)
        if (this.expireAt > 0) {
          Text($r('app.string.days_left', this.daysLeft()))
            .fontSize(12)
            .fontColor(this.expiringSoon() ? $r('app.color.warning') : $r('sys.color.font_secondary'))
        }
      }
      .width('100%')
      .margin({ top: 4 })

      if (this.totalBytes > 0) {
        Row() {
          Row({ space: 4 }) {
            Text(`${Math.round(this.usedRatio() * 100)}%`)
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.lowOnData() ? $r('app.color.warning') : $r('sys.color.font_primary'))
              .fontFeature('"tnum" on')
            Text($r('app.string.used_label'))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .margin({ bottom: 3 })
          }
          .alignItems(VerticalAlign.Bottom)
          .layoutWeight(1)
          Text(`${formatBytes(this.usedBytes)} / ${formatBytes(this.totalBytes)}`)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .fontFeature('"tnum" on')
        }
        .width('100%')
        .margin({ top: 14 })
        Progress({ value: this.usedBytes, total: this.totalBytes, type: ProgressType.Capsule })
          .width('100%')
          .height(8)
          .color(this.lowOnData() ? $r('app.color.warning') : $r('app.color.brand'))
          .backgroundColor($r('app.color.track'))
          .margin({ top: 8 })
      }

      if (this.hasSubscriptionWarning()) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
            .fontSize(14)
            .fontColor([$r('app.color.warning')])
          Text(this.subscriptionWarning())
            .fontSize(12)
            .fontColor($r('app.color.warning'))
        }
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(10)
        .backgroundColor($r('app.color.warning_soft'))
        .margin({ top: 12 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
    .onClick(() => this.onOpenProfiles())
  }

  // ---- ⑤ 代理组 ----
  // 未连接时保留同样的两行，用占位显示，连上后原地填数据。

  @Builder
  GroupCard() {
    Column() {
      this.CardHeader($r('sys.symbol.square_stack_3d'), $r('app.string.card_group'), true)
      Row() {
        Row({ space: 4 }) {
          Text(this.group !== undefined ? `${this.groupNames().length}` : '—')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.group !== undefined ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
            .fontFeature('"tnum" on')
          Text($r('app.string.group_count_unit'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .margin({ bottom: 5 })
        }
        .alignItems(VerticalAlign.Bottom)
        .layoutWeight(1)
        this.GroupAvatars()
      }
      .width('100%')
      .height(40)
      Row({ space: 8 }) {
        Text(this.group !== undefined ? `${this.groupName()} → ${this.groupNode()}` : $r('app.string.after_connect'))
          .fontSize(13)
          .fontColor(this.group !== undefined ? $r('sys.color.font_secondary') : $r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.group !== undefined) {
          Text(this.groupDelay() > 0 ? `${this.groupDelay()} ms` : $r('app.string.delay_untested'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.delayColor(this.groupDelay()))
            .fontFeature('"tnum" on')
        }
      }
      .width('100%')
      .height(20)
      .margin({ top: 10 })
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
    .onClick(() => this.onOpenProxies())
  }

  // 各组名称的首字，最多四个，多出来的显示 +N。
  @Builder
  GroupAvatars() {
    Row({ space: -8 }) {
      ForEach(this.groupNames().slice(0, 4), (name: string) => {
        this.Avatar(this.initialOf(name))
      }, (name: string) => name)
      if (this.groupNames().length > 4) {
        this.Avatar(`+${this.groupNames().length - 4}`)
      }
    }
  }

  @Builder
  Avatar(text: string) {
    Text(text)
      .fontSize(text.startsWith('+') ? 11 : 13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .textAlign(TextAlign.Center)
      .width(30)
      .height(30)
      .borderRadius(15)
      .backgroundColor($r('app.color.tile_background'))
      .border({ width: 2, color: $r('app.color.card_background') })
  }

  // ---- 数据 ----

  private refreshCoreInfo(): void {
    const filesDir = this.context.filesDir;
    getMainGroup(filesDir).then((g: GroupSummary | undefined) => {
      this.group = g;
    }).catch(() => {});
    if (this.conn.mode === '') {
      // 用户没选过时显示配置文件里的模式，不写回偏好。
      getMode(filesDir).then((m: OutboundMode) => {
        this.conn.mode = m;
        this.modeIndex = Math.max(0, MODES.indexOf(m));
      }).catch(() => {});
    }
  }

  private loadExitIp(): void {
    const viaProxy = this.conn.connected;
    this.exitViaProxy = viaProxy;
    this.exitIpState = ExitIpState.Loading;
    lookupExitIp(this.context.filesDir, viaProxy).then((ip: ExitIp | undefined) => {
      if (this.exitViaProxy !== viaProxy) {
        return; // 查询期间连接状态变了，丢掉过期结果
      }
      this.exitIp = ip;
      this.exitIpState = ip !== undefined ? ExitIpState.Ready : ExitIpState.Unavailable;
    }).catch(() => {
      if (this.exitViaProxy === viaProxy) {
        this.exitIpState = ExitIpState.Unavailable;
      }
    });
  }

  private startTicker(): void {
    if (this.ticker !== -1) {
      return;
    }
    this.now = Date.now();
    this.ticker = setInterval(() => {
      this.now = Date.now();
    }, 1000);
  }

  private stopTicker(): void {
    if (this.ticker !== -1) {
      clearInterval(this.ticker);
      this.ticker = -1;
    }
  }

  // ---- 展示用的计算 ----

  private hasFlag(): boolean {
    return this.exitIp !== undefined && flagOf(this.exitIp.countryCode) !== '';
  }

  private regionBadge(): string {
    const ip = this.exitIp;
    if (ip === undefined) {
      return '··';
    }
    const flag = flagOf(ip.countryCode);
    if (flag !== '') {
      return flag;
    }
    return ip.countryCode !== '' ? ip.countryCode.toUpperCase() : '··';
  }

  // 查询服务给的是英文国名，按国家代码换成系统语言的名称。
  private regionName(): string {
    const ip = this.exitIp;
    if (ip === undefined) {
      return '—';
    }
    if (ip.countryCode !== '') {
      try {
        return i18n.System.getDisplayCountry(ip.countryCode, i18n.System.getSystemLocaleInstance().toString(), true);
      } catch (e) {
        // 退回英文国名
      }
    }
    return ip.country !== '' ? ip.country : '—';
  }

  private exitOrg(): string {
    return this.exitIp?.org ?? '';
  }

  private exitAddress(): ResourceStr {
    const ip = this.exitIp;
    if (this.exitIpState === ExitIpState.Unavailable) {
      return '—';
    }
    if (this.exitIpState !== ExitIpState.Ready || ip === undefined) {
      return $r('app.string.exit_ip_loading');
    }
    return this.revealIp ? ip.ip : maskIp(ip.ip);
  }

  private rateValue(upload: boolean): string {
    if (!this.conn.connected) {
      return '—';
    }
    return splitBytes(upload ? this.stats.up : this.stats.down)[0];
  }

  private rateUnit(upload: boolean): string {
    if (!this.conn.connected) {
      return '';
    }
    return `${splitBytes(upload ? this.stats.up : this.stats.down)[1]}/s`;
  }

  private totalText(upload: boolean): string {
    if (!this.conn.connected) {
      return '—';
    }
    return formatBytes(upload ? this.stats.upTotal : this.stats.downTotal);
  }

  private relativeTime(ms: number): ResourceStr {
    if (ms <= 0) {
      return '—';
    }
    const elapsed = Math.max(0, this.now - ms);
    if (elapsed < MINUTE_MS) {
      return $r('app.string.just_now');
    }
    if (elapsed < HOUR_MS) {
      return $r('app.string.minutes_ago', Math.floor(elapsed / MINUTE_MS));
    }
    if (elapsed < DAY_MS) {
      return $r('app.string.hours_ago', Math.floor(elapsed / HOUR_MS));
    }
    return $r('app.string.days_ago', Math.floor(elapsed / DAY_MS));
  }

  private usedRatio(): number {
    return this.totalBytes > 0 ? Math.min(1, this.usedBytes / this.totalBytes) : 0;
  }

  private daysLeft(): number {
    return Math.max(0, Math.ceil((this.expireAt * 1000 - this.now) / DAY_MS));
  }

  private lowOnData(): boolean {
    return this.totalBytes > 0 && 1 - this.usedRatio() < LOW_USAGE_RATIO;
  }

  private expiringSoon(): boolean {
    return this.expireAt > 0 && this.daysLeft() <= EXPIRY_WARN_DAYS;
  }

  private expired(): boolean {
    return this.expireAt > 0 && this.expireAt * 1000 <= this.now;
  }

  private hasSubscriptionWarning(): boolean {
    return this.expired() || this.expiringSoon() || this.lowOnData();
  }

  /** 订阅快用完或快到期时的提醒文字，到期优先。 */
  private subscriptionWarning(): ResourceStr {
    if (this.expired()) {
      return $r('app.string.usage_warn_expired');
    }
    if (this.expiringSoon()) {
      return $r('app.string.usage_warn_expiring', this.daysLeft());
    }
    return $r('app.string.usage_warn_low', formatBytes(this.totalBytes - this.usedBytes));
  }

  private initialOf(name: string): string {
    // 按码点取第一个字符，避免把 emoji 旗标拆成半个代理对。
    const first = name.codePointAt(0);
    return first === undefined ? '' : String.fromCodePoint(first);
  }

  private groupNames(): string[] {
    return this.group?.groups ?? [];
  }

  private groupName(): string {
    return this.group?.group ?? '';
  }

  private groupNode(): string {
    return this.group?.node ?? '';
  }

  private groupDelay(): number {
    return this.group?.delay ?? 0;
  }

  private delayColor(delay: number): Resource {
    if (delay <= 0) {
      return $r('sys.color.font_tertiary');
    }
    if (delay < DELAY_GOOD_MS) {
      return $r('app.color.status_connected');
    }
    return delay < DELAY_SLOW_MS ? $r('app.color.warning') : $r('app.color.status_error');
  }
}
