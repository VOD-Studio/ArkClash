import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { CapsuleSegmentButtonV2, SegmentButtonV2Items, uiMaterial } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { connection, Connection, ConnectionState } from '../../client/Connection';
import { getAllowLan, getMainGroup, getMode, getProxyPort, GroupSummary, OutboundMode } from '../../client/Controller';
import { ExitIp, flagOf, lookupExitIp } from '../../client/ExitIp';
import { checkServices, ServiceResult, ServiceTarget } from '../../client/ServiceCheck';
import { ConnectionStats, connectionStats, MemoryStats, memoryStats } from '../../client/Stats';
import { HISTORY_SIZE, traffic, Traffic } from '../../client/Traffic';
import { EmptyState } from '../../components/EmptyState';
import { LabeledValue, LegendItem, Tag } from '../../components/Labels';
import { formatBytes, splitBytes } from '../../components/Format';
import { SpeedChart } from '../../components/SpeedChart';
import { TabPage } from '../../components/TabPage';
import { CARD, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { lanAddress } from './LanAddress';
import { ServiceCategory, serviceInfo, ServiceLayout, ServiceSlot } from './Services';

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
// 界面进程的内存不随推送更新，按这个间隔取一次。
const UI_MEMORY_EVERY_S = 5;

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
  @Event onScrollDirection: (down: boolean) => void = () => {};
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
  @Local lanIp: string = '';
  @Local proxyPort: number = 0;
  @Local coreAllowLan: boolean = false; // 用户没设置过时，配置文件里的 allow-lan
  @Local serviceDelays: Record<string, number> | undefined = undefined; // id → ms，-1 = 不可达
  @Local checkingServices: boolean = false;
  @Local serviceLayout: ServiceLayout = new ServiceLayout();
  @Local servicesSheet: boolean = false;
  @Local connStats: ConnectionStats = connectionStats;
  @Local memStats: MemoryStats = memoryStats;
  @Local uiMemoryBytes: number = 0;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private ticker: number = -1;
  private modeItems: SegmentButtonV2Items = new SegmentButtonV2Items([
    { text: $r('app.string.mode_rule'), symbol: $r('sys.symbol.list_bullet') },
    { text: $r('app.string.mode_global'), symbol: $r('sys.symbol.paperplane') },
    { text: $r('app.string.mode_direct'), symbol: $r('sys.symbol.arrow_right') }
  ]);

  aboutToAppear(): void {
    this.serviceLayout.load(this.context);
    this.modeIndex = Math.max(0, MODES.indexOf(this.conn.mode as OutboundMode));
    this.sync();
  }

  aboutToDisappear(): void {
    this.stopTicker();
    connectionStats.stop();
    memoryStats.stop();
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
      this.lanIp = lanAddress();
      this.uiMemoryBytes = this.readUiMemory();
    } else {
      this.stopTicker();
    }
    if (this.visible && this.conn.connected) {
      connectionStats.start(this.context.filesDir);
      memoryStats.start(this.context.filesDir);
    } else {
      connectionStats.stop();
      memoryStats.stop();
    }
    if (!this.conn.connected) {
      this.group = undefined;
      this.serviceDelays = undefined;
      this.proxyPort = 0;
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
    Column() {
      TabPage({
        title: $r('app.string.tab_home'),
        topInset: this.topInset,
        scroller: this.scroller,
        onScrollDirection: (down: boolean) => this.onScrollDirection(down)
      }) {
        if (this.profileReady) {
          this.StatusCard()
          this.SpeedCard()
          this.ModeCard()
          this.LanCard()
          this.ServicesCard()
          this.ProfileCard()
          this.GroupCard()
          this.ConnStatsCard()
          this.MemoryCard()
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
    .width('100%')
    .height('100%')
    .bindSheet(this.servicesSheet, this.ServicesSheet(), {
      title: { title: $r('app.string.card_services') },
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      systemMaterial: sheetMaterial(),
      showClose: true,
      onDisappear: () => {
        this.servicesSheet = false;
      }
    })
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

  // ---- ④ 内网 IP ----

  @Builder
  LanCard() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.wifi'))
          .fontSize(18)
          .fontColor([$r('sys.color.font_secondary')])
        Text($r('app.string.card_lan_ip'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.rectangle_on_rectangle'))
            .fontSize(16)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .width(28)
        .height(28)
        .backgroundColor($r('app.color.tile_background'))
        .enabled(this.lanIp !== '')
        .onClick(() => this.copyLanIp())
      }
      .width('100%')
      .height(28)
      .margin({ bottom: 12 })

      Text(this.lanIp !== '' ? this.lanIp : $r('app.string.no_network'))
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.lanIp !== '' ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
        .fontFeature('"tnum" on')
        .maxLines(1)
        .height(34)

      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.dot_radiowaves_left_and_right'))
            .fontSize(18)
            .fontColor([$r('sys.color.font_secondary')])
        }
        .width(36)
        .height(36)
        .borderRadius(18)
        .backgroundColor($r('app.color.card_background'))
        Column({ space: 2 }) {
          Text($r('app.string.lan_proxy'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text(this.lanProxyHint())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .fontFeature('"tnum" on')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.lanProxyOn() })
          .onChange((isOn: boolean) => {
            if (isOn !== this.lanProxyOn()) {
              this.conn.changeAllowLan(isOn);
            }
          })
      }
      .width('100%')
      .padding(12)
      .borderRadius(12)
      .backgroundColor($r('app.color.tile_background'))
      .margin({ top: 12 })
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }

  // ---- ⑤ 服务状态 ----

  @Builder
  ServicesCard() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.link'))
          .fontSize(18)
          .fontColor([$r('sys.color.font_secondary')])
        Text($r('app.string.card_services'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        this.ServicesChip()
        Button({ type: ButtonType.Circle }) {
          if (this.checkingServices) {
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
        .enabled(this.conn.connected && !this.checkingServices)
        .onClick(() => this.runServiceCheck(this.serviceLayout.visibleIds))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('sys.color.font_tertiary')])
      }
      .width('100%')
      .height(28)
      .margin({ bottom: 12 })

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(this.serviceLayout.visibleIds, (id: string) => {
          this.ServiceTile(id)
        }, (id: string) => id)
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
    .onClick(() => this.openServicesSheet())
  }

  @Builder
  ServicesChip() {
    if (this.serviceDelays !== undefined) {
      if (this.downServices() === 0) {
        Tag({
          text: $r('app.string.services_all_ok'),
          color: $r('app.color.status_connected'),
          tint: $r('app.color.success_soft'),
          dot: false
        })
      } else {
        Tag({
          text: $r('app.string.services_some_down', this.downServices()),
          color: $r('app.color.warning'),
          tint: $r('app.color.warning_soft'),
          dot: false
        })
      }
    }
  }

  @Builder
  ServiceTile(id: string) {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        this.ServiceIcon(id, 32)
        Circle()
          .width(10)
          .height(10)
          .fill(this.serviceDotColor(id))
          .stroke($r('app.color.tile_background'))
          .strokeWidth(2)
      }
      .width(32)
      .height(32)
      Column({ space: 2 }) {
        Text(serviceInfo(id)?.name ?? id)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.serviceDelayText(id))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .fontFeature('"tnum" on')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('48.5%')
    .padding(10)
    .borderRadius(12)
    .backgroundColor($r('app.color.tile_background'))
    .margin({ bottom: 8 })
  }

  // 固定白底隔离深色主题，保留产品标志的原始配色，不用统一染色重画品牌。
  @Builder
  ServiceIcon(id: string, size: number) {
    Stack() {
      Image(serviceInfo(id)?.icon)
        .width(size * 0.55)
        .height(size * 0.55)
        .objectFit(ImageFit.Contain)
    }
    .width(size)
    .height(size)
    .borderRadius(size / 2)
    .backgroundColor($r('app.color.service_icon_background'))
  }

  // 抽屉：全部服务的检测结果；长按拖动排序，开关决定是否显示在首页。
  @Builder
  ServicesSheet() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text($r('app.string.services_sheet_hint'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 6 }) {
            if (this.checkingServices) {
              LoadingProgress()
                .width(16)
                .height(16)
            } else {
              SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                .fontSize(14)
                .fontColor([$r('sys.color.font_primary')])
            }
            Text($r('app.string.services_recheck'))
              .fontSize(13)
              .fontColor($r('sys.color.font_primary'))
          }
        }
        .height(32)
        .padding({ left: 12, right: 12 })
        .backgroundColor($r('app.color.tile_background'))
        .enabled(this.conn.connected && !this.checkingServices)
        .onClick(() => this.runServiceCheck(this.allServiceIds()))
      }
      .width('100%')

      List({ space: 8 }) {
        ForEach(this.serviceLayout.slots, (slot: ServiceSlot) => {
          ListItem() {
            this.ServiceRow(slot)
          }
        }, (slot: ServiceSlot) => `${slot.id}:${slot.visible}`)
          .onMove((from: number, to: number) => this.serviceLayout.move(from, to))
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 4, bottom: 16 })
  }

  @Builder
  ServiceRow(slot: ServiceSlot) {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.list_bullet'))
        .fontSize(16)
        .fontColor([$r('sys.color.font_tertiary')])
      Stack({ alignContent: Alignment.BottomEnd }) {
        this.ServiceIcon(slot.id, 36)
        Circle()
          .width(10)
          .height(10)
          .fill(this.serviceDotColor(slot.id))
          .stroke($r('app.color.tile_background'))
          .strokeWidth(2)
      }
      .width(36)
      .height(36)
      Column({ space: 2 }) {
        Text(serviceInfo(slot.id)?.name ?? slot.id)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Row() {
          Text(this.categoryLabel(slot.id))
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
          if (this.serviceDelay(slot.id) !== undefined || this.checkingServices) {
            Text(' · ')
              .fontSize(12)
              .fontColor($r('sys.color.font_tertiary'))
            Text(this.serviceDelayText(slot.id))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .fontFeature('"tnum" on')
          }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: slot.visible })
        .onChange((isOn: boolean) => this.serviceLayout.setVisible(slot.id, isOn))
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor($r('app.color.tile_background'))
  }

  // ---- ⑥ 配置 ----

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

  // ---- ⑦ 代理组 ----
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

  // ---- ⑧ 连接统计 ----

  @Builder
  ConnStatsCard() {
    Column() {
      this.CardHeader($r('sys.symbol.list_bullet'), $r('app.string.card_conn_stats'), false)
      Row() {
        LabeledValue({ label: $r('app.string.stat_active'), value: this.statText(this.connStats.active) })
          .layoutWeight(1)
        LabeledValue({ label: $r('app.string.stat_proxied'), value: this.statText(this.connStats.proxied) })
          .layoutWeight(1)
        LabeledValue({ label: $r('app.string.stat_direct'), value: this.statText(this.connStats.direct) })
          .layoutWeight(1)
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }

  // ---- ⑨ 内存信息 ----

  @Builder
  MemoryCard() {
    Column() {
      this.CardHeader($r('sys.symbol.rectangle_stack'), $r('app.string.card_memory'), false)
      Row({ space: 3 }) {
        Text(splitBytes(this.totalMemory())[0])
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .fontFeature('"tnum" on')
        Text(splitBytes(this.totalMemory())[1])
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .margin({ bottom: 4 })
      }
      .alignItems(VerticalAlign.Bottom)
      // 两段比例条：内核在前，界面在后。
      Row({ space: 2 }) {
        Column()
          .height('100%')
          .layoutWeight(Math.max(1, this.coreMemory()))
          .borderRadius(4)
          .backgroundColor($r('app.color.memory_core'))
        Column()
          .height('100%')
          .layoutWeight(Math.max(1, this.uiMemoryBytes))
          .borderRadius(4)
          .backgroundColor($r('app.color.memory_ui'))
      }
      .width('100%')
      .height(8)
      .margin({ top: 12 })
      Row({ space: 16 }) {
        LegendItem({
          color: $r('app.color.memory_core'),
          label: $r('app.string.mem_core'),
          value: this.memStats.received ? formatBytes(this.memStats.coreBytes) : '—'
        })
        LegendItem({
          color: $r('app.color.memory_ui'),
          label: $r('app.string.mem_ui'),
          value: formatBytes(this.uiMemoryBytes)
        })
      }
      .margin({ top: 10 })
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }

  // ---- 数据 ----

  private refreshCoreInfo(): void {
    const filesDir = this.context.filesDir;
    getProxyPort(filesDir).then((port: number) => {
      this.proxyPort = port;
    }).catch(() => {});
    if (this.conn.allowLan === undefined) {
      getAllowLan(filesDir).then((allow: boolean) => {
        this.coreAllowLan = allow;
      }).catch(() => {});
    }
    if (this.serviceDelays === undefined && !this.checkingServices) {
      this.runServiceCheck(this.serviceLayout.visibleIds);
    }
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

  private runServiceCheck(ids: string[]): void {
    const targets: ServiceTarget[] = [];
    for (const id of ids) {
      const info = serviceInfo(id);
      if (info !== undefined) {
        targets.push({ id: id, url: info.url });
      }
    }
    this.checkingServices = true;
    checkServices(this.context.filesDir, targets).then((results: ServiceResult[]) => {
      if (!this.conn.connected) {
        return;
      }
      const delays: Record<string, number> = {};
      const previous = this.serviceDelays ?? {};
      for (const key of Object.keys(previous)) {
        delays[key] = previous[key];
      }
      for (const r of results) {
        delays[r.id] = r.delay;
      }
      this.serviceDelays = delays;
    }).finally(() => {
      this.checkingServices = false;
    });
  }

  private openServicesSheet(): void {
    this.servicesSheet = true;
    // 抽屉里列出全部服务，没测过的补测一次。
    const delays = this.serviceDelays ?? {};
    const untested = this.allServiceIds().filter((id: string) => delays[id] === undefined);
    if (this.conn.connected && untested.length > 0 && !this.checkingServices) {
      this.runServiceCheck(untested);
    }
  }

  private allServiceIds(): string[] {
    return this.serviceLayout.slots.map((s: ServiceSlot) => s.id);
  }

  private readUiMemory(): number {
    try {
      return Number(hidebug.getPss()) * 1024; // getPss 单位 KB
    } catch (e) {
      return 0;
    }
  }

  private copyLanIp(): void {
    if (this.lanIp === '') {
      return;
    }
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.lanIp);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copied') });
    }).catch(() => {});
  }

  private startTicker(): void {
    if (this.ticker !== -1) {
      return;
    }
    this.now = Date.now();
    let ticks = 0;
    this.ticker = setInterval(() => {
      this.now = Date.now();
      if (++ticks % UI_MEMORY_EVERY_S === 0) {
        this.uiMemoryBytes = this.readUiMemory();
      }
    }, 1000);
  }

  private stopTicker(): void {
    if (this.ticker !== -1) {
      clearInterval(this.ticker);
      this.ticker = -1;
    }
  }

  // ---- 展示用的计算 ----

  private lanProxyOn(): boolean {
    return this.conn.allowLan ?? this.coreAllowLan;
  }

  private lanProxyHint(): ResourceStr {
    if (!this.lanProxyOn()) {
      return $r('app.string.lan_proxy_off');
    }
    if (!this.conn.connected) {
      return $r('app.string.lan_proxy_pending');
    }
    const host = this.lanIp !== '' ? this.lanIp : '—';
    return $r('app.string.lan_proxy_on', this.proxyPort > 0 ? `${host}:${this.proxyPort}` : host);
  }

  private serviceDelay(id: string): number | undefined {
    return this.serviceDelays === undefined ? undefined : this.serviceDelays[id];
  }

  private serviceDelayText(id: string): ResourceStr {
    const delay = this.serviceDelay(id);
    if (delay === undefined) {
      return this.checkingServices ? $r('app.string.services_checking') : '—';
    }
    return delay >= 0 ? `${delay} ms` : $r('app.string.service_down');
  }

  private categoryLabel(id: string): ResourceStr {
    switch (serviceInfo(id)?.category) {
      case ServiceCategory.Ai:
        return 'AI';
      case ServiceCategory.China:
        return $r('app.string.cat_china');
      default:
        return $r('app.string.cat_common');
    }
  }

  private serviceDotColor(id: string): Resource {
    const delay = this.serviceDelay(id);
    if (delay === undefined) {
      return $r('app.color.status_idle');
    }
    return delay >= 0 ? $r('app.color.status_connected') : $r('app.color.status_error');
  }

  private downServices(): number {
    return this.serviceLayout.visibleIds.filter((id: string) => (this.serviceDelay(id) ?? 0) < 0).length;
  }

  private statText(n: number): string {
    return this.conn.connected && this.connStats.received ? n.toLocaleString() : '—';
  }

  private coreMemory(): number {
    return this.memStats.received ? this.memStats.coreBytes : 0;
  }

  private totalMemory(): number {
    return this.coreMemory() + this.uiMemoryBytes;
  }

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
