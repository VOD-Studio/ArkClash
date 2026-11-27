import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { ENTER_OFFSET, enterMotion, NoteCard, PrimaryButton, SecondaryButton, SHEET_CARD_RADIUS,
  SHEET_TILE_SIZE } from '../../components/SheetParts';
import { PAGE_GUTTER } from '../../components/Theme';

/**
 * 删除脚本的确认抽屉：红色图标块、标题和「不能撤销」说明，下方是待删脚本的预览；
 * 还有配置在用它时多一张提示卡列出这些配置。操作区是并排的「取消」和浅红底的「删除」。
 */
@ComponentV2
export struct ScriptDeleteSheet {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require name: string;
  // 远程脚本的来源链接；本地脚本为空。
  @Param url: string = '';
  // 引用这个脚本的配置名，用「、」连好；没有就为空。
  @Param affected: string = '';
  @Param busy: boolean = false;
  @Param motion: boolean = true;
  @Event onConfirm: () => void = (): void => {};
  @Event onCancel: () => void = (): void => {};
  @Local private entered: boolean = false;

  aboutToAppear(): void {
    this.entered = !this.motion;
  }

  @Builder
  Hero() {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.trash')).fontSize(24).fontColor([$r('app.color.status_error')])
      }
      .width(48)
      .height(48)
      .borderRadius(16)
      .backgroundColor($r('app.color.profile_expiry_error_tonal'))
      Column({ space: 2 }) {
        Text($r('app.string.script_delete_title'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(20)
          .lineHeight(26)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text($r('app.string.added_rules_delete_hint'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(2)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
  }

  @Builder
  Preview() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph(this.url === '' ? $r('sys.symbol.doc_text') : $r('sys.symbol.link'))
          .fontSize(20)
          .fontColor([this.appStyle.palette.brand])
      }
      .width(SHEET_TILE_SIZE)
      .height(SHEET_TILE_SIZE)
      .borderRadius(SHEET_TILE_SIZE / 2)
      .backgroundColor(this.appStyle.palette.brandSoft)
      Column({ space: 2 }) {
        Text(this.name)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 远程脚本列出来源链接，同名时也认得出是哪一个；本地脚本只标「本地」。
        Text(this.url === '' ? $r('app.string.script_local') : this.url)
          .fontFamily(this.url === '' ? this.appStyle.fontFamily : 'monospace')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(SHEET_CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
  }

  build() {
    Column({ space: 14 }) {
      Column() { this.Hero() }
        .width('100%')
        .opacity(this.entered ? 1 : 0)
        .translate({ y: this.entered ? 0 : ENTER_OFFSET })
        .animation(enterMotion(this.motion, 0))
      Column() { this.Preview() }
        .width('100%')
        .opacity(this.entered ? 1 : 0)
        .translate({ y: this.entered ? 0 : ENTER_OFFSET })
        .animation(enterMotion(this.motion, 1))
      if (this.affected !== '') {
        Column() {
          NoteCard({ icon: $r('sys.symbol.exclamationmark_circle'),
            text: $r('app.string.script_delete_bound', this.affected) })
        }
        .width('100%')
        .opacity(this.entered ? 1 : 0)
        .translate({ y: this.entered ? 0 : ENTER_OFFSET })
        .animation(enterMotion(this.motion, 2))
      }
      Row({ space: 10 }) {
        SecondaryButton({ label: $r('app.string.action_cancel'), available: !this.busy,
          onPress: (): void => this.onCancel() })
          .layoutWeight(1)
        PrimaryButton({ label: $r('app.string.action_delete'), busyLabel: $r('app.string.action_delete'),
          danger: true, busy: this.busy, onPress: (): void => this.onConfirm() })
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 4 })
      .opacity(this.entered ? 1 : 0)
      .translate({ y: this.entered ? 0 : ENTER_OFFSET })
      .animation(enterMotion(this.motion, this.affected !== '' ? 3 : 2))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 24 })
    .onAppear((): void => { this.entered = true; })
  }
}
