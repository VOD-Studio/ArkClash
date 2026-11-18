import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { common } from '@kit.AbilityKit';
import { connection, Connection } from '../../client/Connection';
import { getMainGroup, GroupSummary } from '../../client/Controller';
import { DASHBOARD_CARD } from '../../components/Theme';
import { DashboardCardHeader } from './DashboardCardHeader';
import { AppGlyph } from '../../components/AppGlyph';
import { DashboardGroupAvatar } from './DashboardGroupAvatar';

@ComponentV2
export struct DashboardGroups {
  @Local private appStyle: AppearanceState = appAppearance;
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
  @Local figureWidth: number = 0;
  private generation: number = 0;
  private target: string = '';
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.sync();
  }

  aboutToDisappear(): void {
    this.generation++;
  }

  @Monitor('visible', 'profileId', 'routeRevision', 'conn.routeRevision', 'conn.state', 'conn.coreReady', 'conn.mode')
  sync(): void {
    const target = `${this.profileId}:${this.routeRevision}:${this.conn.routeRevision}:${this.conn.mode}`;
    if (target !== this.target || !this.conn.coreReady) {
      this.summary = undefined;
      this.failed = false;
      this.target = target;
    }
    this.generation++;
    this.loading = false;
    if (this.visible && this.conn.coreReady) {
      this.refresh();
    }
  }

  private async refresh(): Promise<void> {
    const generation = ++this.generation;
    this.loading = true;
    this.failed = false;
    try {
      const summary = await getMainGroup(this.context.filesDir);
      if (generation === this.generation && this.visible && this.conn.coreReady) {
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
    if (this.conn.coreReady) {
      return this.summary?.groups ?? [];
    }
    return this.summaryGroups;
  }

  private iconSource(name: string): string {
    const icons = this.conn.coreReady ? this.summary?.groupIcons : this.summaryGroupIcons;
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

  private avatarCount(): number {
    const count = this.names().length;
    return Math.min(4, count) + (count > 4 ? 1 : 0);
  }

  private avatarSize(): number {
    if (this.figureWidth <= 8 || this.avatarCount() === 0) {
      return 40;
    }
    return Math.min(40, (this.figureWidth - 8) / 2 / (1 + (this.avatarCount() - 1) * 0.8));
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        DashboardCardHeader({ title: $r('app.string.card_group'), glyph: 'layers',
          chevron: this.names().length > 0 })
          .layoutWeight(1)
        if (this.summary !== undefined && this.summary.delay < 0) {
          Text($r('app.string.dash_delay_timeout'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(11)
            .fontWeight(600)
            .fontColor($r('app.color.warning'))
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .borderRadius(7)
            .backgroundColor(this.appStyle.palette.tileBackground)
        }
      }
      .width('100%')
      if (this.names().length > 0) {
        Row({ space: 8 }) {
          Text() {
            Span(`${this.names().length}`)
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(40)
              .fontWeight(FontWeight.Bold)
              .letterSpacing(-0.8)
            Span(' ')
              .fontFamily(this.appStyle.fontFamily)
            Span($r('app.string.group_count_unit'))
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(15)
              .fontWeight(600)
              .fontColor($r('sys.color.font_secondary'))
          }
          .lineHeight(44)
          .fontFeature('"tnum" on')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Clip })
          .layoutWeight(1)
          Stack({ alignContent: Alignment.TopStart }) {
            ForEach(this.names().slice(0, 4), (name: string, index: number): void => {
              DashboardGroupAvatar({ groupName: name, iconSource: this.iconSource(name), badgeSize: this.avatarSize() })
                .position({ x: index * this.avatarSize() * 0.8, y: 0 })
            }, (name: string): string => name)
            if (this.names().length > 4) {
              Text(`+${this.names().length - 4}`)
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(this.avatarSize() * 0.3)
                .fontWeight(600)
                .textAlign(TextAlign.Center)
                .fontColor($r('sys.color.font_secondary'))
                .width(this.avatarSize())
                .height(this.avatarSize())
                .borderRadius(this.avatarSize() * 0.35)
                .backgroundColor(this.appStyle.palette.tileBackground)
                .border({ width: this.avatarSize() * 0.075, color: this.appStyle.palette.cardBackground })
                .position({ x: 4 * this.avatarSize() * 0.8, y: 0 })
            }
          }
          .width(this.avatarSize() * (1 + (this.avatarCount() - 1) * 0.8))
          .height(this.avatarSize())
        }
        .width('100%')
        .onAreaChange((_previous: Area, current: Area): void => { this.figureWidth = Number(current.width); })
      } else {
        Column({ space: 6 }) {
          Stack() {
            AppGlyph({ name: 'layers', iconSize: 26, iconColor: $r('sys.color.font_secondary') })
          }
          .width(64)
          .height(64)
          .borderRadius(22)
          .backgroundColor(this.appStyle.palette.tileBackground)
          Text(this.hint())
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(15)
            .lineHeight(20)
            .fontWeight(600)
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
          if (this.failed) {
            Button($r('app.string.dash_retry'))
              .fontFamily(this.appStyle.fontFamily)
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
    .backgroundColor(this.appStyle.palette.cardBackground)
    .onClick((): void => { if (this.interactive && this.names().length > 0) { this.onOpen(); } })
  }
}
