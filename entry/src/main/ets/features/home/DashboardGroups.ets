import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { getMainGroup, GroupSummary } from '../../client/Controller';
import { CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';

@ComponentV2
export struct DashboardGroups {
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Param profileReady: boolean = false;
  @Param profileId: string = '';
  @Param routeRevision: string = '';
  @Param summaryGroups: string[] = [];
  @Event onOpen: () => void = () => {};
  @Local conn: Connection = connection;
  @Local summary: GroupSummary | undefined = undefined;
  @Local loading: boolean = false;
  @Local failed: boolean = false;
  private generation: number = 0;
  private target: string = '';
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.sync();
  }

  aboutToDisappear(): void {
    this.generation++;
  }

  @Monitor('visible', 'profileId', 'routeRevision', 'conn.routeRevision', 'conn.state', 'conn.mode')
  sync(): void {
    const target = `${this.profileId}:${this.routeRevision}:${this.conn.routeRevision}:${this.conn.mode}`;
    if (target !== this.target || !this.conn.connected) {
      this.summary = undefined;
      this.failed = false;
      this.target = target;
    }
    this.generation++;
    this.loading = false;
    if (this.visible && this.conn.connected) {
      this.refresh();
    }
  }

  private async refresh(): Promise<void> {
    const generation = ++this.generation;
    this.loading = true;
    this.failed = false;
    try {
      const summary = await getMainGroup(this.context.filesDir);
      if (generation === this.generation && this.visible && this.conn.connected) {
        this.summary = summary;
      }
    } catch (e) {
      if (generation === this.generation) {
        this.failed = true;
      }
    } finally {
      if (generation === this.generation) {
        this.loading = false;
      }
    }
  }

  private names(): string[] {
    if (this.conn.mode === 'direct') {
      return [];
    }
    if (this.conn.connected) {
      return this.summary?.groups ?? [];
    }
    return this.summaryGroups;
  }

  private initial(name: string): string {
    const point = name.codePointAt(0);
    return point === undefined ? '?' : String.fromCodePoint(point);
  }

  private hint(): ResourceStr {
    if (this.loading) {
      return $r('app.string.dash_groups_loading');
    }
    if (this.failed) {
      return $r('app.string.dash_groups_failed');
    }
    if (!this.profileReady) {
      return $r('app.string.home_no_profile');
    }
    if (this.names().length === 0) {
      return $r('app.string.dash_groups_empty');
    }
    if (this.summary !== undefined) {
      return `${this.summary.group} → ${this.summary.node || '—'}`;
    }
    return $r('app.string.node_after_connect');
  }

  build() {
    Column({ space: 12 }) {
      DashboardCardHeader({ title: $r('app.string.card_group'), symbol: $r('sys.symbol.square_stack_3d'),
        chevron: this.names().length > 0 })
      Row() {
        Text(this.conn.connected && this.conn.mode !== 'direct' && this.summary === undefined ? '—' :
          `${this.names().length}`)
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Row({ space: -8 }) {
          ForEach(this.names().slice(0, 4), (name: string): void => {
            Text(this.initial(name))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Center)
              .width(32)
              .height(32)
              .borderRadius(16)
              .backgroundColor($r('app.color.tile_background'))
              .border({ width: 2, color: $r('app.color.card_background') })
          }, (name: string): string => name)
          if (this.names().length > 4) {
            Text(`+${this.names().length - 4}`)
              .fontSize(12)
              .textAlign(TextAlign.Center)
              .width(32)
              .height(32)
              .borderRadius(16)
              .backgroundColor($r('app.color.tile_background'))
              .border({ width: 2, color: $r('app.color.card_background') })
          }
        }
      }
      .width('100%')
      Text(this.hint())
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.summary !== undefined && this.summary.delay !== 0) {
        Text(this.summary.delay < 0 ? $r('app.string.dash_delay_timeout') : `${this.summary.delay} ms`)
          .fontSize(13)
          .fontColor(this.summary.delay > 0 && this.summary.delay < 600 ? $r('app.color.status_connected') :
            $r('app.color.warning'))
      }
      if (this.failed) {
        Button($r('app.string.dash_retry'))
          .enabled(this.interactive && !this.loading)
          .onClick((): void => { this.refresh(); })
      } else if (this.names().length > 0) {
        Button($r('app.string.action_switch_node'))
          .enabled(this.interactive)
          .onClick((): void => { this.onOpen(); })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }
}
