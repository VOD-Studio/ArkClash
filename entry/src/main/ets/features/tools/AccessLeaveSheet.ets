import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { VpnAppAccessMode } from '../../shared/VpnNetwork';
import { AccessControlChanges, AccessListChange } from './AccessControlLogic';

const SHEET_CARD_RADIUS = 20;
const ACTION_HEIGHT = 48;
// 错误说明放进浅色衬底卡；生效提示只是一行脚注，左右与卡片内文字略微对齐。
const ERROR_NOTE_PADDING: Padding = { left: 14, right: 14, top: 14, bottom: 14 };
const HINT_NOTE_PADDING: Padding = { left: 4, right: 4, top: 0, bottom: 0 };

function modeLabel(mode: VpnAppAccessMode): Resource {
  if (mode === 'trusted') { return $r('app.string.access_control_mode_trusted'); }
  if (mode === 'blocked') { return $r('app.string.access_control_mode_blocked'); }
  return $r('app.string.access_control_mode_off');
}

/**
 * 应用访问控制的离开确认页：标题区、修改摘要卡、不能保存的原因和操作区。
 * 保存不了时禁用保存并在卡片下方给出原因，不让用户点了保存再被 Toast 打回。
 */
@ComponentV2
export struct AccessLeaveSheet {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require changes: AccessControlChanges;
  @Param issue: ResourceStr = '';
  @Param reconnect: boolean = false;
  @Param saving: boolean = false;
  @Event onSave: () => void = (): void => {};
  @Event onDiscard: () => void = (): void => {};
  @Event onKeep: () => void = (): void => {};

  @Computed
  get modeChanged(): boolean {
    return this.changes.fromMode !== this.changes.toMode;
  }

  @Computed
  get rowCount(): number {
    return (this.modeChanged ? 1 : 0) + this.changes.lists.length;
  }

  @Computed
  get blocked(): boolean {
    return this.issue !== '';
  }

  @Builder
  IconTile(icon: Resource) {
    Stack() {
      SymbolGlyph(icon).fontSize(18).fontColor([this.appStyle.palette.brand])
    }
    .width(34)
    .height(34)
    .borderRadius(17)
    .backgroundColor(this.appStyle.palette.brandSoft)
  }

  @Builder
  CountChip(text: string, spoken: Resource, error: boolean) {
    Text(text)
      .fontFamily(this.appStyle.fontFamily)
      .fontSize(13)
      .lineHeight(16)
      .fontWeight(600)
      .fontFeature('"tnum" on')
      .fontColor(error ? $r('app.color.status_error') : this.appStyle.palette.brand)
      .height(24)
      .padding({ left: 9, right: 9 })
      .borderRadius(12)
      .backgroundColor(error ? $r('app.color.profile_expiry_error_tonal') : this.appStyle.palette.profileExpiryTonal)
      .accessibilityText(spoken)
  }

  @Builder
  Hero() {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(26).fontColor([this.appStyle.palette.brand])
      }
      .width(56)
      .height(56)
      .borderRadius(18)
      .backgroundColor(this.appStyle.palette.profileExpiryTonal)
      Column({ space: 2 }) {
        Text($r('app.string.access_control_unsaved_title'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(20)
          .lineHeight(26)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text($r('app.string.access_control_unsaved_hint'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(14)
          .lineHeight(20)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  ModeRow() {
    Row({ space: 14 }) {
      this.IconTile($r('sys.symbol.slider_horizontal_2'))
      Column({ space: 2 }) {
        Text($r('app.string.access_control_change_mode'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor($r('sys.color.font_secondary'))
        // 模式名在英文下较长，旧值和新值单独成行，窄屏时允许换行而不是截断新值。
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          Text(modeLabel(this.changes.fromMode))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(15)
            .lineHeight(22)
            .fontColor($r('sys.color.font_secondary'))
          SymbolGlyph($r('sys.symbol.arrow_right'))
            .fontSize(14)
            .fontColor([$r('sys.color.font_tertiary')])
            .margin({ left: 6, right: 6 })
          Text(modeLabel(this.changes.toMode))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(15)
            .lineHeight(22)
            .fontWeight(600)
            .fontColor(this.appStyle.palette.brand)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 14, right: 16, top: 10, bottom: 10 })
  }

  @Builder
  ListRow(item: AccessListChange) {
    Row({ space: 14 }) {
      this.IconTile($r('sys.symbol.square_grid_2x2'))
      Text(item.mode === 'trusted' ?
        $r('app.string.access_control_change_trusted') : $r('app.string.access_control_change_blocked'))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(15)
        .lineHeight(22)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Row({ space: 6 }) {
        if (item.added > 0) {
          this.CountChip(`+${item.added}`, $r('app.string.access_control_change_added', item.added), false)
        }
        if (item.removed > 0) {
          this.CountChip(`−${item.removed}`, $r('app.string.access_control_change_removed', item.removed), true)
        }
      }
    }
    .width('100%')
    .height(64)
    .padding({ left: 14, right: 16 })
  }

  @Builder
  Changes() {
    Column() {
      if (this.modeChanged) {
        this.ModeRow()
      }
      ForEach(this.changes.lists, (item: AccessListChange, index: number) => {
        if (this.modeChanged || index > 0) {
          Divider().color(this.appStyle.palette.divider).margin({ left: 62, right: 16 })
        }
        this.ListRow(item)
      }, (item: AccessListChange): string => `${item.mode}:${item.added}:${item.removed}`)
    }
    .width('100%')
    .borderRadius(SHEET_CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .clip(true)
  }

  @Builder
  Note(icon: Resource, text: ResourceStr, error: boolean) {
    Row({ space: 10 }) {
      SymbolGlyph(icon)
        .fontSize(18)
        .fontColor([error ? $r('app.color.status_error') : $r('sys.color.font_secondary')])
      Text(text)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(14)
        .lineHeight(20)
        .fontColor(error ? $r('app.color.status_error') : $r('sys.color.font_secondary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(error ? ERROR_NOTE_PADDING : HINT_NOTE_PADDING)
    .borderRadius(SHEET_CARD_RADIUS)
    .backgroundColor(error ? $r('app.color.profile_expiry_error_tonal') : Color.Transparent)
  }

  @Builder
  Actions() {
    Column({ space: 10 }) {
      Button({ type: ButtonType.Capsule, stateEffect: true }) {
        Row({ space: 8 }) {
          if (this.saving) {
            LoadingProgress().width(20).height(20).color(this.appStyle.palette.onBrand)
          }
          Text(this.saving ? $r('app.string.access_control_saving') : $r('app.string.action_save'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(16)
            .fontWeight(600)
            .fontColor(this.appStyle.palette.onBrand)
        }
      }
      .width('100%')
      .height(ACTION_HEIGHT)
      .backgroundColor(this.appStyle.palette.brand)
      .enabled(!this.saving && !this.blocked)
      .onClick((): void => this.onSave())

      Row({ space: 10 }) {
        Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.NORMAL }) {
          Text($r('app.string.profile_discard'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(16)
            .fontWeight(500)
            .fontColor($r('app.color.status_error'))
        }
        .layoutWeight(1)
        .height(ACTION_HEIGHT)
        .enabled(!this.saving)
        .onClick((): void => this.onDiscard())

        Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.NORMAL }) {
          Text($r('app.string.profile_keep_editing'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(16)
            .fontWeight(500)
            .fontColor($r('sys.color.font_primary'))
        }
        .layoutWeight(1)
        .height(ACTION_HEIGHT)
        .enabled(!this.saving)
        .onClick((): void => this.onKeep())
      }
      .width('100%')
    }
    .width('100%')
    .margin({ top: 4 })
  }

  build() {
    Column({ space: 14 }) {
      this.Hero()
      if (this.rowCount > 0) {
        this.Changes()
      }
      if (this.blocked) {
        this.Note($r('sys.symbol.exclamationmark_triangle'), this.issue, true)
      } else if (this.reconnect) {
        this.Note($r('sys.symbol.arrow_2_circlepath'), $r('app.string.access_control_change_reconnect'), false)
      }
      this.Actions()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 24 })
  }
}
