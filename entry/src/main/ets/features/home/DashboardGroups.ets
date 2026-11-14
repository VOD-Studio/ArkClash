import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { getMainGroup, GroupSummary } from '../../client/Controller';
import { dashboardCardShadow, DASHBOARD_CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';
import { AppGlyph } from '../../components/AppGlyph';
import { DashboardGroupAvatar } from './DashboardGroupAvatar';

@ComponentV2
export struct DashboardGroups {
  @Param visible: boolean = false;
  @Param interactive: boolean = true;
  @Param profileReady: boolean = false;
  @Param profileId: string = '';
  @Param routeRevision: string = '';
  @Param summaryGroups: string[] = [];
  @Param summaryGroupIcons: Record<string, string> = {};
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

  private iconSource(name: string): string {
    const icons = this.conn.connected ? this.summary?.groupIcons : this.summaryGroupIcons;
    return icons === undefined ? '' : icons[name] ?? '';
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
      Row({ space: 8 }) {
        DashboardCardHeader({ title: $r('app.string.card_group'), glyph: 'layers',
          chevron: this.names().length > 0 })
          .layoutWeight(1)
        if (this.summary !== undefined && this.summary.delay < 0) {
          Text($r('app.string.dash_delay_timeout'))
            .fontSize(11)
            .fontWeight(600)
            .fontColor($r('app.color.warning'))
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .borderRadius(7)
            .backgroundColor($r('app.color.tile_background'))
        }
      }
      .width('100%')
      if (this.names().length > 0) {
        Row({ space: 12 }) {
          Text() {
            Span(`${this.names().length}`)
              .fontSize(40)
              .fontWeight(FontWeight.Bold)
              .letterSpacing(-0.8)
            Span(' ')
            Span($r('app.string.group_count_unit'))
              .fontSize(15)
              .fontWeight(600)
              .fontColor($r('sys.color.font_secondary'))
          }
          .lineHeight(44)
          .fontFeature('"tnum" on')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Clip })
          .layoutWeight(1)
          Row({ space: -8 }) {
            ForEach(this.names().slice(0, 4), (name: string): void => {
              DashboardGroupAvatar({ groupName: name, iconSource: this.iconSource(name) })
            }, (name: string): string => name)
            if (this.names().length > 4) {
              Text(`+${this.names().length - 4}`)
                .fontSize(12)
                .fontWeight(600)
                .textAlign(TextAlign.Center)
                .fontColor($r('sys.color.font_secondary'))
                .width(40)
                .height(40)
                .borderRadius(14)
                .backgroundColor($r('app.color.tile_background'))
                .border({ width: 3, color: $r('app.color.card_background') })
            }
          }
        }
        .width('100%')
      } else {
        Column({ space: 6 }) {
          Stack() {
            AppGlyph({ name: 'layers', iconSize: 26, iconColor: $r('sys.color.font_secondary') })
          }
          .width(64)
          .height(64)
          .borderRadius(22)
          .backgroundColor($r('app.color.tile_background'))
          Text(this.hint())
            .fontSize(15)
            .lineHeight(20)
            .fontWeight(600)
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
          if (this.failed) {
            Button($r('app.string.dash_retry'))
              .enabled(this.interactive && !this.loading)
              .onClick((): void => { this.refresh(); })
          }
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(DASHBOARD_CARD)
    .background(dashboardCardShadow)
    .onClick((): void => { if (this.interactive && this.names().length > 0) { this.onOpen(); } })
  }
}
