import { AddedRule, newAddedRule } from '../../client/AddedRules';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { SettingsSection } from './SettingsSection';

interface PresetRule {
  kind: string;
  payload: string;
  target: string;
  noResolve?: boolean;
}

class AddedRulePreset {
  readonly id: string;
  readonly label: Resource;
  readonly icon: Resource;
  readonly rules: PresetRule[];

  constructor(id: string, label: Resource, icon: Resource, rules: PresetRule[]) {
    this.id = id;
    this.label = label;
    this.icon = icon;
    this.rules = rules;
  }
}

const PRESETS: AddedRulePreset[] = [
  new AddedRulePreset('quic', $r('app.string.added_rules_quic'), $r('sys.symbol.bolt'), [
    { kind: 'AND', payload: '((NETWORK,UDP),(DST-PORT,443))', target: 'REJECT-DROP' }
  ]),
  new AddedRulePreset('stun', $r('app.string.added_rules_stun'), $r('sys.symbol.eye_slash'), [
    { kind: 'AND', payload: '((NETWORK,UDP),(DST-PORT,3478/19302))', target: 'REJECT-DROP' }
  ]),
  new AddedRulePreset('dot', $r('app.string.added_rules_dot'), $r('sys.symbol.connection'), [
    { kind: 'DST-PORT', payload: '853', target: 'REJECT' }
  ]),
  new AddedRulePreset('loopback', $r('app.string.added_rules_loopback'), $r('sys.symbol.arrow_2_circlepath'), [
    { kind: 'IP-CIDR', payload: '127.0.0.0/8', target: 'REJECT', noResolve: true },
    { kind: 'IP-CIDR', payload: '0.0.0.0/32', target: 'REJECT', noResolve: true },
    { kind: 'IP-CIDR6', payload: '::1/128', target: 'REJECT', noResolve: true },
    { kind: 'IP-CIDR6', payload: '::/128', target: 'REJECT', noResolve: true },
    { kind: 'AND', payload: '((IN-TYPE,TUN),(DST-PORT,853))', target: 'REJECT' }
  ]),
  new AddedRulePreset('lan', $r('app.string.added_rules_lan'), $r('sys.symbol.wifi'), [
    { kind: 'GEOSITE', payload: 'private', target: 'DIRECT' },
    { kind: 'GEOIP', payload: 'LAN', target: 'DIRECT', noResolve: true }
  ]),
  new AddedRulePreset('system', $r('app.string.added_rules_system'), $r('sys.symbol.nearby_devices'), [
    { kind: 'GEOSITE', payload: 'apple', target: 'DIRECT' },
    { kind: 'GEOSITE', payload: 'microsoft', target: 'DIRECT' }
  ]),
  new AddedRulePreset('tracker', $r('app.string.added_rules_tracker'), $r('sys.symbol.arrow_down'), [
    { kind: 'GEOSITE', payload: 'category-public-tracker', target: 'DIRECT' },
    { kind: 'GEOSITE', payload: 'category-pt', target: 'DIRECT' }
  ])
];

@ComponentV2
export struct AddedRulePresets {
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private selectedIds: string[] = [];
  @Param saving: boolean = false;
  @Event onAdd: (rules: AddedRule[]) => void = () => {};

  private toggle(id: string): void {
    this.selectedIds = this.selectedIds.includes(id) ?
      this.selectedIds.filter((item: string): boolean => item !== id) : this.selectedIds.concat([id]);
  }

  private confirm(): void {
    const rules: AddedRule[] = [];
    for (const preset of PRESETS) {
      if (this.selectedIds.includes(preset.id)) {
        for (const rule of preset.rules) {
          rules.push(newAddedRule(rule.kind, rule.payload, rule.target, rule.noResolve ?? false));
        }
      }
    }
    this.onAdd(rules);
  }

  @Builder
  PresetRows() {
    ForEach(PRESETS, (preset: AddedRulePreset, index: number) => {
      if (index > 0) {
        Divider().color(this.appStyle.palette.divider).margin({ left: 50, right: 16 })
      }
      Row({ space: 12 }) {
        SymbolGlyph(preset.icon).fontSize(22).fontColor([$r('sys.color.font_primary')])
        Column({ space: 4 }) {
          Text(preset.label).fontFamily(this.appStyle.fontFamily).fontSize(16).fontColor($r('sys.color.font_primary'))
          ForEach(preset.rules, (rule: PresetRule) => {
            Text([rule.kind, rule.payload, rule.target].join(',') + (rule.noResolve ? ',no-resolve' : ''))
              .fontFamily('monospace').fontSize(12).fontColor($r('sys.color.font_secondary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }, (rule: PresetRule): string => rule.kind + ',' + rule.payload)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.selectedIds.includes(preset.id)) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([this.appStyle.palette.brand])
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .accessibilitySelected(this.selectedIds.includes(preset.id))
      .onClick((): void => this.toggle(preset.id))
    }, (preset: AddedRulePreset): string => preset.id)
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        SettingsSection({ rows: (): void => this.PresetRows() })
        Button($r('app.string.added_rules_confirm'))
          .width('100%')
          .enabled(this.selectedIds.length > 0 && !this.saving)
          .onClick((): void => this.confirm())
      }
      .width('100%').enabled(!this.saving)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
  }
}
