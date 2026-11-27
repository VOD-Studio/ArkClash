import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { RULE_CARD_RADIUS, RULE_ENTER_OFFSET, RulePrimaryButton, RuleSecondaryButton, RuleTone, ruleEnter,
  ruleTargetTone } from './AddedRuleSheetParts';

/** 删除确认里预览的一条规则：类型、内容（规则集显示名称）和策略。 */
export interface RuleDeletePreview {
  key: string;
  kind: string;
  payload: string;
  target: string;
  customExit: boolean;
}

// 预览最多列几条；再多就用一行「以及另外 N 条」收尾，抽屉高度不随选择数量无限增长。
export const RULE_DELETE_PREVIEW_LIMIT = 3;

/**
 * 删除附加规则的确认抽屉：红色图标块、标题和「不能撤销」说明，
 * 下方列出将被删除的规则，操作区是并排的「取消」和浅红底的「删除」。
 */
@ComponentV2
export struct AddedRuleDeleteSheet {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param previews: RuleDeletePreview[] = [];
  @Param total: number = 0;
  @Param saving: boolean = false;
  @Param motion: boolean = true;
  @Event onConfirm: () => void = (): void => {};
  @Event onCancel: () => void = (): void => {};
  @Local private entered: boolean = false;

  aboutToAppear(): void {
    this.entered = !this.motion;
  }

  private tone(item: RuleDeletePreview): RuleTone {
    return item.customExit ? 'brand' : ruleTargetTone(item.target);
  }

  private targetColor(item: RuleDeletePreview): ResourceColor {
    const tone = this.tone(item);
    if (tone === 'success') { return $r('app.color.status_connected'); }
    if (tone === 'error') { return $r('app.color.status_error'); }
    if (tone === 'brand') { return this.appStyle.palette.brand; }
    return $r('sys.color.font_secondary');
  }

  private targetLabel(item: RuleDeletePreview): string {
    if (item.customExit) { return item.target; }
    return item.target === 'MATCH' ? 'MATCH-TARGET' : item.target;
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
        Text($r('app.string.added_rules_delete_count', this.total))
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
  PreviewRow(item: RuleDeletePreview) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(item.kind)
          .fontFamily('monospace')
          .fontSize(14)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.payload)
          .fontFamily('monospace')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(this.targetLabel(item))
        .fontFamily(item.customExit ? this.appStyle.fontFamily : 'monospace')
        .fontSize(13)
        .fontWeight(600)
        .fontColor(this.targetColor(item))
        .constraintSize({ maxWidth: '45%' })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  @Builder
  Previews() {
    Column() {
      ForEach(this.previews, (item: RuleDeletePreview, index: number) => {
        if (index > 0) {
          Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
        }
        this.PreviewRow(item)
      }, (item: RuleDeletePreview): string => item.key)
      if (this.total > this.previews.length) {
        Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
        Text($r('app.string.added_rules_delete_more', this.total - this.previews.length))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .height(44)
          .padding({ left: 16, right: 16 })
      }
    }
    .width('100%')
    .borderRadius(RULE_CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .clip(true)
  }

  build() {
    Column({ space: 14 }) {
      Column() { this.Hero() }
        .width('100%')
        .opacity(this.entered ? 1 : 0)
        .translate({ y: this.entered ? 0 : RULE_ENTER_OFFSET })
        .animation(ruleEnter(this.motion, 0))
      if (this.previews.length > 0) {
        Column() { this.Previews() }
          .width('100%')
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : RULE_ENTER_OFFSET })
          .animation(ruleEnter(this.motion, 1))
      }
      Row({ space: 10 }) {
        RuleSecondaryButton({ label: $r('app.string.action_cancel'), available: !this.saving,
          onPress: (): void => this.onCancel() })
          .layoutWeight(1)
        RulePrimaryButton({ label: $r('app.string.action_delete'), busyLabel: $r('app.string.action_delete'),
          danger: true, busy: this.saving, onPress: (): void => this.onConfirm() })
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 4 })
      .opacity(this.entered ? 1 : 0)
      .translate({ y: this.entered ? 0 : RULE_ENTER_OFFSET })
      .animation(ruleEnter(this.motion, 2))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 24 })
    .onAppear((): void => { this.entered = true; })
  }
}
