import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { VpnAppAccessMode } from '../../shared/VpnNetwork';
import { AccessControlChanges, AccessListChange } from './AccessControlLogic';

const SHEET_CARD_RADIUS = 20;
const ACTION_HEIGHT = 48;
const SUMMARY_ROW_HEIGHT = 48;

function modeLabel(mode: VpnAppAccessMode): Resource {
  return mode === 'trusted' ? $r('app.string.access_control_mode_trusted') : $r('app.string.access_control_mode_blocked');
}

/**
 * 访问控制的离开确认：标题、修改摘要和「放弃 / 保存」两个按钮；继续编辑靠下滑或点遮罩。
 * 保存不了时禁用保存并在摘要下方给出原因，不让用户点了保存再被 Toast 打回。
 */
@ComponentV2
export struct AccessLeaveSheet {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require changes: AccessControlChanges;
  @Param issue: ResourceStr = '';
  @Param saving: boolean = false;
  @Event onSave: () => void = (): void => {};
  @Event onDiscard: () => void = (): void => {};

  @Computed
  get switchChanged(): boolean {
    return (this.changes.fromMode === 'off') !== (this.changes.toMode === 'off');
  }

  @Computed
  get modeChanged(): boolean {
    return this.changes.fromMode !== 'off' && this.changes.toMode !== 'off' &&
      this.changes.fromMode !== this.changes.toMode;
  }

  @Computed
  get blocked(): boolean {
    return this.issue !== '';
  }

  @Builder
  SummaryRow(label: ResourceStr, value: ResourceStr, divider: boolean) {
    Column() {
      if (divider) {
        Divider().color(this.appStyle.palette.divider).margin({ left: 16 })
      }
      Row({ space: 12 }) {
        Text(label)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
        Text(value)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .fontWeight(500)
          .fontFeature('"tnum" on')
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(SUMMARY_ROW_HEIGHT)
      .padding({ left: 16, right: 16 })
    }
  }

  @Builder
  ModeSummary(divider: boolean) {
    Column() {
      if (divider) {
        Divider().color(this.appStyle.palette.divider).margin({ left: 16 })
      }
      Row({ space: 6 }) {
        Text($r('app.string.access_control_change_mode'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
        Text(modeLabel(this.changes.fromMode))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .fontColor($r('sys.color.font_secondary'))
        SymbolGlyph($r('sys.symbol.arrow_right')).fontSize(14).fontColor([$r('sys.color.font_tertiary')])
        Text(modeLabel(this.changes.toMode))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .fontWeight(500)
          .fontColor($r('sys.color.font_primary'))
      }
      .width('100%')
      .height(SUMMARY_ROW_HEIGHT)
      .padding({ left: 16, right: 16 })
    }
  }

  @Builder
  ListSummary(item: AccessListChange, divider: boolean) {
    this.SummaryRow(
      item.mode === 'trusted' ? $r('app.string.access_control_change_trusted') :
        $r('app.string.access_control_change_blocked'),
      [item.added > 0 ? `+${item.added}` : '', item.removed > 0 ? `−${item.removed}` : '']
        .filter((part: string): boolean => part !== '').join('  '),
      divider)
  }

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.access_control_unsaved_title'))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(20)
        .lineHeight(26)
        .fontWeight(600)
        .fontColor($r('sys.color.font_primary'))
        .padding({ left: 4 })

      Column() {
        if (this.switchChanged) {
          this.SummaryRow($r('app.string.access_control_title'), this.changes.toMode === 'off' ?
            $r('app.string.access_control_mode_off') : $r('app.string.access_control_state_on'), false)
        }
        if (this.modeChanged) {
          this.ModeSummary(this.switchChanged)
        }
        ForEach(this.changes.lists, (item: AccessListChange) => {
          this.ListSummary(item, this.switchChanged || this.modeChanged)
        }, (item: AccessListChange): string => `${item.mode}:${item.added}:${item.removed}`)
      }
      .width('100%')
      .borderRadius(SHEET_CARD_RADIUS)
      .backgroundColor(this.appStyle.palette.cardBackground)
      .clip(true)

      if (this.blocked) {
        Text(this.issue)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor($r('app.color.status_error'))
          .padding({ left: 4 })
      }

      Row({ space: 10 }) {
        Button({ type: ButtonType.Capsule, buttonStyle: ButtonStyleMode.NORMAL }) {
          Text($r('app.string.profile_discard'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(16)
            .fontWeight(600)
            .fontColor($r('app.color.status_error'))
        }
        .layoutWeight(1)
        .height(ACTION_HEIGHT)
        .enabled(!this.saving)
        .onClick((): void => this.onDiscard())

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
        .layoutWeight(1)
        .height(ACTION_HEIGHT)
        .backgroundColor(this.appStyle.palette.brand)
        .opacity(this.blocked ? 0.4 : 1)
        .enabled(!this.saving && !this.blocked)
        .onClick((): void => this.onSave())
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 20, bottom: 24 })
  }
}
