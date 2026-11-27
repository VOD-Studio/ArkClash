import { LengthMetrics } from '@kit.ArkUI';
import { AddedRule, addedRuleText, newAddedRule } from '../../client/AddedRules';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { ENTER_OFFSET, enterMotion, pressEffect, PrimaryButton, SETTLE_SPRING, SHEET_CARD_RADIUS,
  SheetHeader } from '../../components/SheetParts';
import { ruleTargetTone } from './AddedRuleTone';

interface PresetRule {
  kind: string;
  payload: string;
  target: string;
  noResolve?: boolean;
}

class AddedRulePreset {
  readonly id: string;
  readonly label: Resource;
  readonly hint: Resource;
  readonly icon: Resource;
  readonly rules: PresetRule[];
  // 与已有规则比对用的规则文本，以及卡片上展示的去重策略名。
  readonly texts: string[];
  readonly targets: string[];

  constructor(id: string, label: Resource, hint: Resource, icon: Resource, rules: PresetRule[]) {
    this.id = id;
    this.label = label;
    this.hint = hint;
    this.icon = icon;
    this.rules = rules;
    this.texts = rules.map((rule: PresetRule): string =>
      addedRuleText(newAddedRule(rule.kind, rule.payload, rule.target, rule.noResolve ?? false)));
    this.targets = rules.map((rule: PresetRule): string => rule.target)
      .filter((target: string, index: number, all: string[]): boolean => all.indexOf(target) === index);
  }
}

const PRESETS: AddedRulePreset[] = [
  new AddedRulePreset('quic', $r('app.string.added_rules_quic'), $r('app.string.added_rules_quic_hint'),
    $r('sys.symbol.bolt'), [
    { kind: 'AND', payload: '((NETWORK,UDP),(DST-PORT,443))', target: 'REJECT-DROP' }
  ]),
  new AddedRulePreset('stun', $r('app.string.added_rules_stun'), $r('app.string.added_rules_stun_hint'),
    $r('sys.symbol.eye_slash'), [
    { kind: 'AND', payload: '((NETWORK,UDP),(DST-PORT,3478/19302))', target: 'REJECT-DROP' }
  ]),
  new AddedRulePreset('dot', $r('app.string.added_rules_dot'), $r('app.string.added_rules_dot_hint'),
    $r('sys.symbol.lock_shield'), [
    { kind: 'DST-PORT', payload: '853', target: 'REJECT' }
  ]),
  new AddedRulePreset('loopback', $r('app.string.added_rules_loopback'), $r('app.string.added_rules_loopback_hint'),
    $r('sys.symbol.arrow_2_circlepath'), [
    { kind: 'IP-CIDR', payload: '127.0.0.0/8', target: 'REJECT', noResolve: true },
    { kind: 'IP-CIDR', payload: '0.0.0.0/32', target: 'REJECT', noResolve: true },
    { kind: 'IP-CIDR6', payload: '::1/128', target: 'REJECT', noResolve: true },
    { kind: 'IP-CIDR6', payload: '::/128', target: 'REJECT', noResolve: true },
    { kind: 'AND', payload: '((IN-TYPE,TUN),(DST-PORT,853))', target: 'REJECT' }
  ]),
  new AddedRulePreset('lan', $r('app.string.added_rules_lan'), $r('app.string.added_rules_lan_hint'),
    $r('sys.symbol.wifi_router'), [
    { kind: 'GEOSITE', payload: 'private', target: 'DIRECT' },
    { kind: 'GEOIP', payload: 'LAN', target: 'DIRECT', noResolve: true }
  ]),
  new AddedRulePreset('system', $r('app.string.added_rules_system'), $r('app.string.added_rules_system_hint'),
    $r('sys.symbol.nearby_devices'), [
    { kind: 'GEOSITE', payload: 'apple', target: 'DIRECT' },
    { kind: 'GEOSITE', payload: 'microsoft', target: 'DIRECT' }
  ]),
  new AddedRulePreset('tracker', $r('app.string.added_rules_tracker'), $r('app.string.added_rules_tracker_hint'),
    $r('sys.symbol.arrow_down'), [
    { kind: 'GEOSITE', payload: 'category-public-tracker', target: 'DIRECT' },
    { kind: 'GEOSITE', payload: 'category-pt', target: 'DIRECT' }
  ])
];

/**
 * 快捷操作抽屉：每个预设一张可勾选的卡片，写明用途和会用到的策略；
 * 规则已全部存在的预设标成「已添加」且不可选，底部按钮直接写出将要新增的条数。
 */
@ComponentV2
export struct AddedRulePresets {
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private selectedIds: string[] = [];
  @Local private entered: boolean = false;
  @Param saving: boolean = false;
  /** 当前列表里已有规则的 addedRuleText，用来判断预设是否已经加过。 */
  @Param existing: string[] = [];
  @Param motion: boolean = true;
  @Event onAdd: (rules: AddedRule[]) => void = () => {};
  @Event onClose: () => void = () => {};

  aboutToAppear(): void {
    this.entered = !this.motion;
  }

  private freshRules(preset: AddedRulePreset): PresetRule[] {
    return preset.rules.filter((_rule: PresetRule, index: number): boolean =>
      !this.existing.includes(preset.texts[index]));
  }

  private added(preset: AddedRulePreset): boolean {
    return this.freshRules(preset).length === 0;
  }

  @Computed
  get pendingCount(): number {
    let count = 0;
    for (const preset of PRESETS) {
      if (this.selectedIds.includes(preset.id)) {
        count += this.freshRules(preset).length;
      }
    }
    return count;
  }

  private toggle(id: string): void {
    this.selectedIds = this.selectedIds.includes(id) ?
      this.selectedIds.filter((item: string): boolean => item !== id) : this.selectedIds.concat([id]);
  }

  private confirm(): void {
    const rules: AddedRule[] = [];
    for (const preset of PRESETS) {
      if (this.selectedIds.includes(preset.id)) {
        for (const rule of this.freshRules(preset)) {
          rules.push(newAddedRule(rule.kind, rule.payload, rule.target, rule.noResolve ?? false));
        }
      }
    }
    this.onAdd(rules);
  }

  build() {
    // 预设内容超过一屏：标题和添加按钮固定，中间的卡片列表单独滚动，两端渐隐。
    Column() {
      Column() {
        SheetHeader({ icon: $r('sys.symbol.bolt_fill'), heading: $r('app.string.added_rules_presets'),
          subheading: $r('app.string.added_rules_presets_hint'), closable: !this.saving,
          onClose: (): void => this.onClose() })
      }
      .width('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 20, bottom: 14 })
      .opacity(this.entered ? 1 : 0)
      .translate({ y: this.entered ? 0 : ENTER_OFFSET })
      .animation(enterMotion(this.motion, 0))
      Scroll() {
        Column({ space: 10 }) {
          ForEach(PRESETS, (preset: AddedRulePreset, index: number) => {
            Column() {
              AddedRulePresetCard({ preset: preset, selected: this.selectedIds.includes(preset.id),
                added: this.added(preset), motion: this.motion, onTap: (): void => this.toggle(preset.id) })
            }
            .width('100%')
            .opacity(this.entered ? 1 : 0)
            .translate({ y: this.entered ? 0 : ENTER_OFFSET })
            .animation(enterMotion(this.motion, index + 1))
          }, (preset: AddedRulePreset): string => preset.id)
        }
        .width('100%')
        .enabled(!this.saving)
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 4, bottom: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(16) })
      .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      Column() {
        PrimaryButton({
          label: this.pendingCount > 0 ? $r('app.string.added_rules_presets_add', this.pendingCount) :
            $r('app.string.added_rules_presets_pick'),
          busy: this.saving, available: this.pendingCount > 0, onPress: (): void => this.confirm()
        })
      }
      .width('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
      .opacity(this.entered ? 1 : 0)
      .translate({ y: this.entered ? 0 : ENTER_OFFSET })
      .animation(enterMotion(this.motion, 3))
    }
    .width('100%')
    .height('100%')
    .onAppear((): void => { this.entered = true; })
  }
}

@ComponentV2
struct AddedRulePresetCard {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require preset: AddedRulePreset;
  @Param selected: boolean = false;
  @Param added: boolean = false;
  @Param motion: boolean = true;
  @Event onTap: () => void = () => {};
  private readonly checkSwap: ReplaceSymbolEffect = new ReplaceSymbolEffect(EffectScope.WHOLE);

  private settle(): AnimateParam {
    return this.motion ? { curve: SETTLE_SPRING } : { duration: 0 };
  }

  @Builder
  TargetPill(target: string) {
    Text(target)
      .fontFamily('monospace')
      .fontSize(11)
      .lineHeight(14)
      .fontWeight(600)
      .fontColor(ruleTargetTone(target) === 'success' ? $r('app.color.success_foreground') :
        ruleTargetTone(target) === 'error' ? $r('app.color.status_error') : this.appStyle.palette.brand)
      .height(20)
      .padding({ left: 7, right: 7 })
      .borderRadius(10)
      .backgroundColor(ruleTargetTone(target) === 'success' ? $r('app.color.success_soft') :
        ruleTargetTone(target) === 'error' ? $r('app.color.error_soft') : this.appStyle.palette.brandSoft)
  }

  build() {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph(this.preset.icon)
          .fontSize(22)
          .fontColor([this.selected ? this.appStyle.palette.onBrand : this.appStyle.palette.brand])
      }
      .width(44)
      .height(44)
      .borderRadius(22)
      .backgroundColor(this.selected ? this.appStyle.palette.brand : this.appStyle.palette.brandSoft)
      .animation(this.settle())
      Column({ space: 3 }) {
        Text(this.preset.label)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .lineHeight(22)
          .fontWeight(500)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.preset.hint)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 6 }) {
          ForEach(this.preset.targets, (target: string) => {
            this.TargetPill(target)
          }, (target: string): string => target)
          Text($r('app.string.added_rules_presets_count', this.preset.rules.length))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
            .maxLines(1)
        }
        .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.added) {
        Text($r('app.string.added_rules_presets_added'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .fontWeight(600)
          .fontColor(this.appStyle.palette.brand)
          .height(24)
          .padding({ left: 10, right: 10 })
          .borderRadius(12)
          .backgroundColor(this.appStyle.palette.profileExpiryTonal)
      } else {
        SymbolGlyph(this.selected ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize(24)
          .fontColor([this.selected ? this.appStyle.palette.brand : $r('sys.color.icon_fourth')])
          .symbolEffect(this.checkSwap, this.motion && this.selected ? 1 : 0)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 16, top: 14, bottom: 14 })
    .borderRadius(SHEET_CARD_RADIUS)
    .backgroundColor(this.selected ? this.appStyle.palette.selectionTonal : this.appStyle.palette.cardBackground)
    .animation(this.settle())
    .opacity(this.added ? 0.6 : 1)
    .clickEffect(this.added ? null : pressEffect(this.motion))
    .accessibilityGroup(true)
    .accessibilitySelected(this.selected)
    .onClick((): void => {
      if (!this.added) {
        this.onTap();
      }
    })
  }
}
