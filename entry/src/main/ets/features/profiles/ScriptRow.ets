import { SymbolGlyphModifier } from '@kit.ArkUI';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { formatUpdatedAgo } from '../../components/Format';
import { sectionTransition, SHEET_CARD_RADIUS, SHEET_ROW_HEIGHT, SHEET_TEXT_INSET,
  SHEET_TILE_SIZE } from '../../components/SheetParts';
import { ConfigScript } from '../../shared/profiles/Scripts';

/**
 * 脚本列表的一行：来源图标块、名称、「来源 · 更新时间」，右侧是更多按钮。
 * 排序时右侧换成拖动把手，同步时换成转圈；三者叠在同一格里交替，行本身不重建，切换有过渡。
 */
@ComponentV2
@ReusableV2
export struct ScriptRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require item: ConfigScript;
  @Param first: boolean = false;
  @Param last: boolean = false;
  @Param sorting: boolean = false;
  @Param updating: boolean = false;
  @Param now: number = 0;
  @Param motion: boolean = true;
  @Event onEdit: () => void = (): void => {};
  @Event onUrl: () => void = (): void => {};
  @Event onSync: () => void = (): void => {};
  @Event onDelete: () => void = (): void => {};

  private remote(): boolean {
    return this.item.url !== '';
  }

  @Builder
  RowActions() {
    Menu() {
      MenuItem({ content: $r('app.string.action_edit'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')) })
        .onClick((): void => this.onEdit())
      if (this.remote()) {
        MenuItem({ content: $r('app.string.script_url'),
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.link')) })
          .onClick((): void => this.onUrl())
        MenuItem({ content: $r('app.string.script_sync'),
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise')) })
          .onClick((): void => this.onSync())
      }
      MenuItem({ content: $r('app.string.action_delete'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash')).fontColor([$r('app.color.status_error')]) })
        .contentFontColor($r('app.color.status_error'))
        .onClick((): void => this.onDelete())
    }
  }

  @Builder
  Label() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph(this.remote() ? $r('sys.symbol.link') : $r('sys.symbol.doc_text'))
          .fontSize(20)
          .fontColor([this.appStyle.palette.brand])
      }
      .width(SHEET_TILE_SIZE)
      .height(SHEET_TILE_SIZE)
      .borderRadius(SHEET_TILE_SIZE / 2)
      .backgroundColor(this.appStyle.palette.brandSoft)
      Column({ space: 2 }) {
        Text(this.item.name)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .lineHeight(22)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text() {
          Span(this.remote() ? $r('app.string.script_remote') : $r('app.string.script_local'))
          Span(' · ')
          Span(formatUpdatedAgo(this.item.updatedAt, this.now))
        }
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(13)
        .lineHeight(18)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 8 })
  }

  @Builder
  Accessory() {
    Stack() {
      if (this.updating) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(this.appStyle.palette.brand)
          .transition(sectionTransition(this.motion))
      } else if (this.sorting) {
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontSize(20)
          .fontColor([$r('sys.color.font_secondary')])
          .accessibilityText($r('app.string.profile_sort'))
          .transition(sectionTransition(this.motion))
      } else {
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(20).fontColor([$r('sys.color.font_secondary')])
        }
        .width(40)
        .height(40)
        .accessibilityText($r('app.string.action_more'))
        .bindMenu(this.RowActions)
        .transition(sectionTransition(this.motion))
      }
    }
    .width(40)
    .height(40)
  }

  build() {
    Column() {
      Row() {
        // 整块文字区借系统按压态；排序或同步时不接收触摸，长按直接交给列表拖动。
        Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          this.Label()
        }
        .layoutWeight(1)
        .height('100%')
        .borderRadius(0)
        .padding(0)
        .hitTestBehavior(this.sorting || this.updating ? HitTestMode.None : HitTestMode.Default)
        .bindContextMenu(this.RowActions, ResponseType.LongPress)
        .onClick((): void => this.onEdit())
        this.Accessory()
      }
      .width('100%')
      .height(SHEET_ROW_HEIGHT)
      .padding({ right: 8 })
      if (!this.last) {
        Divider().color(this.appStyle.palette.divider).margin({ left: SHEET_TEXT_INSET, right: 16 })
      }
    }
    .width('100%')
    .borderRadius({
      topLeft: this.first ? SHEET_CARD_RADIUS : 0, topRight: this.first ? SHEET_CARD_RADIUS : 0,
      bottomLeft: this.last ? SHEET_CARD_RADIUS : 0, bottomRight: this.last ? SHEET_CARD_RADIUS : 0
    })
    .backgroundColor(this.appStyle.palette.cardBackground)
    .clip(true)
  }
}
