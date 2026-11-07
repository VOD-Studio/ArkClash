import { common } from '@kit.AbilityKit';
import { connection, Connection, ConnectionState } from '../../client/Connection';
import { getMainGroup, GroupSummary } from '../../client/Controller';
import { traffic, Traffic } from '../../client/Traffic';
import { formatSpeed } from '../../components/Format';

const BUTTON_SIZE = 40;

/**
 * 悬浮页签栏旁的迷你栏，对应音乐应用的「正在播放」。收起时只露出最左边的连接按钮；
 * 页面滚动、页签栏收起时展开，显示状态、当前节点和实时速率。
 */
@ComponentV2
export struct ConnectionBar {
  @Param expanded: boolean = false;
  @Event onOpen: () => void = () => {};
  @Local conn: Connection = connection;
  @Local stats: Traffic = traffic;
  @Local group: GroupSummary | undefined = undefined;
  @Local barHeight: number = 0;
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  @Monitor('expanded', 'conn.state')
  refresh(): void {
    if (!this.conn.connected) {
      this.group = undefined;
      return;
    }
    if (this.expanded) {
      getMainGroup(this.context.filesDir).then((g: GroupSummary | undefined) => {
        this.group = g;
      }).catch(() => {});
    }
  }

  build() {
    Row({ space: 10 }) {
      Button({ type: ButtonType.Circle }) {
        if (this.conn.busy) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(this.connectedLike() ? $r('app.color.on_brand') : $r('app.color.brand'))
        } else {
          SymbolGlyph(this.connectedLike() ? $r('sys.symbol.pause') : $r('sys.symbol.power'))
            .fontSize(20)
            .fontColor([this.connectedLike() ? $r('app.color.on_brand') : $r('app.color.brand')])
        }
      }
      .width(BUTTON_SIZE)
      .height(BUTTON_SIZE)
      .backgroundColor(this.connectedLike() ? $r('app.color.brand') : $r('app.color.brand_soft'))
      .enabled(!this.conn.busy)
      .onClick(() => {
        if (this.connectedLike()) {
          this.conn.disconnect(this.context);
        } else {
          this.conn.connect(this.context);
        }
      })

      if (this.expanded) {
        Column({ space: 2 }) {
          Text(this.primaryText())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.secondaryText())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .fontFeature('"tnum" on')
            .maxLines(1)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .onClick(() => this.onOpen())
      }
    }
    .height('100%')
    // 收起时迷你栏是直径等于栏高的圆，按钮放在左端那个正方形的正中；展开后按钮位置不变。
    .padding({ left: Math.max(0, (this.barHeight - BUTTON_SIZE) / 2), right: 12 })
    .onAreaChange((_old: Area, area: Area) => {
      this.barHeight = area.height as number;
    })
  }

  private connectedLike(): boolean {
    return this.conn.state === ConnectionState.Connected || this.conn.state === ConnectionState.Disconnecting;
  }

  private primaryText(): ResourceStr {
    if (this.conn.connected && this.group !== undefined) {
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
    if (!this.conn.connected) {
      return $r('app.string.bar_tap_to_connect');
    }
    return `↓ ${formatSpeed(this.stats.down)}  ↑ ${formatSpeed(this.stats.up)}`;
  }
}
