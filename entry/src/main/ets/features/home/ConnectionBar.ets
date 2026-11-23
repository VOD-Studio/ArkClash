import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { common } from '@kit.AbilityKit';
import { connection, Connection, ConnectionState } from '../../client/Connection';
import { getMainGroup, GroupSummary } from '../../client/Controller';
import { traffic, Traffic } from '../../client/Traffic';
import { formatSpeed } from '../../components/Format';
import {
  homeHasPendingCleanup, homeRunActionLabel, homeRunFailureMessage, homeRuntimeAppearsStarted, homeShouldStopRuntime
} from './HomeRunControls';

const BUTTON_SIZE = 40;

/**
 * 悬浮页签栏旁的迷你栏，对应音乐应用的「正在播放」。收起时只露出最左边的连接按钮；
 * 页面滚动、页签栏收起时展开，显示状态、当前节点和实时速率。
 */
@ComponentV2
export struct ConnectionBar {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param expanded: boolean = false;
  @Param visible: boolean = false;
  @Event onOpen: () => void = () => {};
  @Local conn: Connection = connection;
  @Local stats: Traffic = traffic;
  @Local group: GroupSummary | undefined = undefined;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private generation: number = 0;

  @Monitor('expanded', 'conn.state', 'conn.coreReady', 'conn.routeRevision', 'conn.mode')
  refresh(): void {
    const generation = ++this.generation;
    this.group = undefined;
    if (this.expanded && this.conn.coreReady) {
      getMainGroup(this.context.filesDir).then((group: GroupSummary | undefined): void => {
        if (generation === this.generation && this.expanded && this.conn.coreReady) {
          this.group = group;
        }
      }).catch(() => {});
    }
  }

  build() {
    Row({ space: 2 }) {
      // 迷你栏重建时也能在首帧居中，展开时按钮仍在左端等高的正方形内。
      Stack({ alignContent: Alignment.Center }) {
        Button({ type: ButtonType.Circle }) {
          if (this.conn.busy) {
            LoadingProgress()
              .width(22)
              .height(22)
              .color(this.connectedLike() ? this.appStyle.palette.onBrand : this.appStyle.palette.brand)
          } else {
            SymbolGlyph(this.connectedLike() ? $r('sys.symbol.pause') : $r('sys.symbol.power'))
              .fontSize(20)
              .fontColor([this.connectedLike() ? this.appStyle.palette.onBrand : this.appStyle.palette.brand])
          }
        }
        .width(BUTTON_SIZE)
        .height(BUTTON_SIZE)
        .backgroundColor(this.connectedLike() ? this.appStyle.palette.brand : this.appStyle.palette.brandSoft)
        .enabled(this.conn.state !== ConnectionState.Disconnecting)
        .accessibilityText(homeRunActionLabel(this.conn.intent, this.conn.forward, this.conn.listenersOpen,
          this.conn.tunAttached, this.conn.vpnCreated, this.conn.hostState))
        .onClick((): void => {
          const shouldStop = homeShouldStopRuntime(this.conn.intent, this.conn.forward, this.conn.listenersOpen,
            this.conn.tunAttached, this.conn.vpnCreated, this.conn.hostState);
          const operation = shouldStop ? this.conn.disconnect(this.context) : this.conn.connect(this.context);
          operation.catch((error: Error): void => {
            if (this.visible) {
              const message = homeRunFailureMessage(error.message, this.cleanupPending(),
                shouldStop ? $r('app.string.dash_vpn_stop_failed') : $r('app.string.dash_vpn_connect_failed'));
              this.getUIContext().getPromptAction().showToast({ message: message, duration: 4000 });
            }
          });
        })
      }
      .height('100%')
      .aspectRatio(1)

      if (this.expanded) {
        Column({ space: 2 }) {
          Text(this.primaryText())
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.secondaryText())
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .fontFeature('"tnum" on')
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ right: 12 })
        .onClick(() => this.onOpen())
      }
    }
    .height('100%')
  }

  private connectedLike(): boolean {
    return homeRuntimeAppearsStarted(this.conn.intent, this.conn.forward, this.conn.listenersOpen,
      this.conn.tunAttached, this.conn.vpnCreated, this.conn.hostState) ||
      this.conn.state === ConnectionState.Disconnecting;
  }

  private cleanupPending(): boolean {
    return homeHasPendingCleanup(this.conn.forward, this.conn.listenersOpen, this.conn.tunAttached,
      this.conn.vpnCreated, this.conn.hostState);
  }

  private primaryText(): ResourceStr {
    if (this.conn.hostState === 'unknown' && !this.conn.busy) {
      return $r('app.string.dash_runtime_unknown');
    }
    if (this.cleanupPending() && this.conn.state !== ConnectionState.Disconnecting) {
      return $r('app.string.dash_cleanup_required');
    }
    if (this.conn.coreReady && this.group !== undefined) {
      return this.group.node;
    }
    switch (this.conn.state) {
      case ConnectionState.Connecting:
        return $r('app.string.status_connecting');
      case ConnectionState.Connected:
        return $r('app.string.status_connected');
      case ConnectionState.Disconnecting:
        return $r('app.string.status_disconnecting');
      default:
        return $r('app.string.status_disconnected');
    }
  }

  private secondaryText(): ResourceStr {
    if (this.conn.hostState === 'unknown' && !this.conn.busy) {
      return $r('app.string.dash_runtime_tap_to_confirm');
    }
    if (this.cleanupPending()) {
      return $r('app.string.dash_stop_retry');
    }
    if (!this.conn.connected) {
      return $r('app.string.bar_tap_to_connect');
    }
    return this.stats.stale ? $r('app.string.dash_traffic_stale') :
      `↓ ${formatSpeed(this.stats.down)}  ↑ ${formatSpeed(this.stats.up)}`;
  }
}
