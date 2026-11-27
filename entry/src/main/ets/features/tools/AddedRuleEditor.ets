import { LengthMetrics } from '@kit.ArkUI';
import { AddedRule, ADDED_RULE_KINDS, ADDED_RULE_TARGETS, addedRuleHasParams } from '../../client/AddedRules';
import { RuleSetItem } from '../../client/RuleSets';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { RULE_CARD_RADIUS, RULE_ENTER_OFFSET, RULE_ROW_HEIGHT, RULE_SETTLE_SPRING, RULE_TEXT_INSET,
  RULE_TILE_SIZE, RuleChip, RuleNote, RulePrimaryButton, RuleSecondaryButton, RuleSheetHeader, ruleEnter,
  ruleSectionTransition, ruleTargetTone } from './AddedRuleSheetParts';

@ObservedV2
export class AddedRuleDraft {
  readonly original: AddedRule;
  @Trace kind: string;
  @Trace payloadText: string;
  @Trace target: string;
  @Trace customExit: boolean;
  @Trace noResolve: boolean;
  @Trace source: boolean;

  constructor(rule: AddedRule) {
    this.original = rule;
    this.kind = rule.kind;
    this.payloadText = rule.payload;
    this.target = rule.target;
    this.customExit = rule.customExit === true;
    this.noResolve = rule.noResolve;
    this.source = rule.source;
  }

  dirty(): boolean {
    return this.kind !== this.original.kind || this.payloadText !== this.original.payload ||
      this.target !== this.original.target || this.customExit !== (this.original.customExit === true) ||
      this.noResolve !== this.original.noResolve ||
      this.source !== this.original.source;
  }

  rule(): AddedRule {
    const params = addedRuleHasParams(this.kind);
    return { id: this.original.id, kind: this.kind, payload: this.payloadText.trim(), target: this.target.trim(),
      customExit: this.customExit ? true : undefined,
      noResolve: params && this.noResolve, source: params && this.source };
  }
}

class RuleKindGroup {
  readonly id: string;
  readonly label: Resource;
  readonly icon: Resource;
  readonly kinds: string[];

  constructor(id: string, label: Resource, icon: Resource, kinds: string[]) {
    this.id = id;
    this.label = label;
    this.icon = icon;
    // 只保留内核支持的类型，列表增删时分组不会冒出无效项。
    this.kinds = kinds.filter((kind: string): boolean => ADDED_RULE_KINDS.includes(kind));
  }
}

const GROUPED_KINDS: RuleKindGroup[] = [
  new RuleKindGroup('domain', $r('app.string.added_rules_kind_domain'), $r('sys.symbol.link'),
    ['DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD', 'DOMAIN-REGEX', 'DOMAIN-WILDCARD', 'GEOSITE']),
  new RuleKindGroup('ip', $r('app.string.added_rules_kind_ip'), $r('sys.symbol.wifi_router'),
    ['IP-CIDR', 'IP-CIDR6', 'IP-SUFFIX', 'IP-ASN', 'GEOIP']),
  new RuleKindGroup('source', $r('app.string.added_rules_kind_source'), $r('sys.symbol.smallcircle_filled_circle'),
    ['SRC-GEOIP', 'SRC-IP-ASN', 'SRC-IP-CIDR', 'SRC-IP-SUFFIX', 'SRC-PORT']),
  new RuleKindGroup('inbound', $r('app.string.added_rules_kind_inbound'), $r('sys.symbol.connection'),
    ['DST-PORT', 'IN-PORT', 'IN-TYPE', 'IN-USER', 'IN-NAME']),
  new RuleKindGroup('logic', $r('app.string.added_rules_kind_logic'), $r('sys.symbol.arrow_triangle_merge'),
    ['AND', 'OR', 'NOT']),
  new RuleKindGroup('rule-set', $r('app.string.rule_set_title'), $r('sys.symbol.rectangle_stack'), ['RULE-SET'])
];

// 没归入上面分组的类型（包括以后新增的）统一放进「其他」，菜单里不会漏项。
const KIND_GROUPS: RuleKindGroup[] = GROUPED_KINDS.slice(0, GROUPED_KINDS.length - 1).concat([
  new RuleKindGroup('other', $r('app.string.added_rules_kind_other'), $r('sys.symbol.slider_horizontal_2'),
    ADDED_RULE_KINDS.filter((kind: string): boolean =>
      !GROUPED_KINDS.some((group: RuleKindGroup): boolean => group.kinds.includes(kind)))),
  GROUPED_KINDS[GROUPED_KINDS.length - 1]
]);

function kindGroupIndex(kind: string): number {
  return Math.max(0, KIND_GROUPS.findIndex((group: RuleKindGroup): boolean => group.kinds.includes(kind)));
}

// 内容框的占位用该类型的一个真实写法，比通用的「输入规则内容」更能说明格式。
const KIND_EXAMPLES: Record<string, string> = {
  'DOMAIN': 'www.example.com', 'DOMAIN-SUFFIX': 'example.com', 'DOMAIN-KEYWORD': 'google',
  'DOMAIN-REGEX': '^ad\\..*\\.com$', 'DOMAIN-WILDCARD': '*.example.com', 'GEOSITE': 'youtube',
  'IP-CIDR': '192.168.0.0/16', 'IP-CIDR6': '2001:db8::/32', 'IP-SUFFIX': '8.8.8.8/24', 'IP-ASN': '13335',
  'GEOIP': 'CN', 'SRC-GEOIP': 'CN', 'SRC-IP-ASN': '13335', 'SRC-IP-CIDR': '192.168.1.0/24',
  'SRC-IP-SUFFIX': '192.168.1.201/8', 'DST-PORT': '443', 'SRC-PORT': '7777', 'IN-PORT': '7890',
  'IN-TYPE': 'TUN', 'IN-USER': 'mihomo', 'IN-NAME': 'tun-in', 'NETWORK': 'UDP', 'DSCP': '4',
  'AND': '((NETWORK,UDP),(DST-PORT,443))', 'OR': '((DOMAIN,a.com),(DOMAIN,b.com))', 'NOT': '((DOMAIN,example.com))'
};

const PAYLOAD_INPUT_ID = 'added-rule-payload';

type TargetChoiceKind = 'builtin' | 'exit' | 'new';

/** 策略横排里的一个选项：内置策略、已有命名出口，或「新建命名出口」。 */
class TargetChoice {
  readonly key: string;
  readonly kind: TargetChoiceKind;
  readonly value: string;
  readonly label: ResourceStr;

  constructor(kind: TargetChoiceKind, value: string, label: ResourceStr) {
    this.key = `${kind}:${value}`;
    this.kind = kind;
    this.value = value;
    this.label = label;
  }
}

const BUILTIN_TARGET_CHOICES: TargetChoice[] = ADDED_RULE_TARGETS.map((target: string): TargetChoice =>
  new TargetChoice('builtin', target, target === 'MATCH' ? 'MATCH-TARGET' : target));
const NEW_EXIT_CHOICE: TargetChoice = new TargetChoice('new', '', $r('app.string.added_rules_exit_new'));

@ComponentV2
export struct AddedRuleEditor {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require draft: AddedRuleDraft;
  @Param editing: boolean = false;
  @Param saving: boolean = false;
  @Param discardRequested: boolean = false;
  @Param issue: ResourceStr = '';
  @Param ruleSets: RuleSetItem[] = [];
  @Param knownExits: string[] = [];
  @Param motion: boolean = true;
  @Event onSave: () => void = () => {};
  @Event onCancel: () => void = () => {};
  @Event onDiscard: () => void = () => {};
  @Event onResume: () => void = () => {};
  @Event onChange: () => void = () => {};
  @Local private entered: boolean = false;
  // 正在给新出口起名。和 draft.target 分开记：名字敲到与已有出口同名时，输入框不能突然消失。
  @Local private naming: boolean = false;
  private readonly iconSwap: ReplaceSymbolEffect = new ReplaceSymbolEffect(EffectScope.WHOLE);
  // 横排打开时让当前策略露在视野里，前面再留半个邻居，看得出还能往回滑。
  private targetStart: number = 0;

  aboutToAppear(): void {
    this.entered = !this.motion;
    this.naming = this.draft.customExit && !this.knownExits.includes(this.draft.target);
    const selected = this.targetChoices.findIndex((choice: TargetChoice): boolean => this.chosen(choice));
    this.targetStart = Math.max(0, selected - 1);
  }

  @Computed
  get targetChoices(): TargetChoice[] {
    return BUILTIN_TARGET_CHOICES.concat(
      this.knownExits.map((name: string): TargetChoice => new TargetChoice('exit', name, name)), [NEW_EXIT_CHOICE]);
  }

  private chosen(choice: TargetChoice): boolean {
    if (choice.kind === 'new') {
      return this.naming;
    }
    if (choice.kind === 'exit') {
      return this.draft.customExit && !this.naming && this.draft.target === choice.value;
    }
    return !this.draft.customExit && this.draft.target === choice.value;
  }

  private pickTarget(choice: TargetChoice): void {
    if (choice.kind === 'new') {
      this.pickNewExit();
    } else if (choice.kind === 'exit') {
      this.pickExit(choice.value);
    } else {
      this.pickBuiltin(choice.value);
    }
  }

  @Computed
  get groupIndex(): number {
    return kindGroupIndex(this.draft.kind);
  }

  @Computed
  get ruleSetName(): string {
    return this.ruleSets.find((item: RuleSetItem): boolean => item.id === this.draft.payloadText)?.name ?? '';
  }

  @Computed
  get ready(): boolean {
    if (this.draft.kind === 'RULE-SET') {
      return this.ruleSetName !== '';
    }
    return this.draft.payloadText.trim() !== '' && (!this.draft.customExit || this.draft.target.trim() !== '');
  }

  /** 改草稿并让随之出现、消失的区块用弹簧过渡；减弱动态时直接改。 */
  private change(apply: () => void): void {
    if (this.motion) {
      this.getUIContext().animateTo({ curve: RULE_SETTLE_SPRING }, apply);
    } else {
      apply();
    }
    this.onChange();
  }

  private pickKind(next: string): void {
    if (next === this.draft.kind) {
      return;
    }
    this.change((): void => {
      if (next === 'RULE-SET' || this.draft.kind === 'RULE-SET') {
        this.draft.payloadText = '';
      }
      this.draft.kind = next;
    });
  }

  private pickBuiltin(target: string): void {
    this.change((): void => {
      this.draft.customExit = false;
      this.draft.target = target;
      this.naming = false;
    });
  }

  private pickExit(name: string): void {
    this.change((): void => {
      this.draft.customExit = true;
      this.draft.target = name;
      this.naming = false;
    });
  }

  private pickNewExit(): void {
    if (this.naming) {
      return;
    }
    this.change((): void => {
      this.draft.customExit = true;
      this.draft.target = '';
      this.naming = true;
    });
  }

  @Builder
  Caption(label: ResourceStr) {
    Text(label)
      .fontFamily(this.appStyle.fontFamily)
      .fontSize(13)
      .lineHeight(18)
      .fontColor($r('sys.color.font_secondary'))
      .maxLines(1)
  }

  @Builder
  Tile(icon: Resource, swap: boolean) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([this.appStyle.palette.brand])
        .symbolEffect(this.iconSwap, swap && this.motion ? this.groupIndex : 0)
    }
    .width(RULE_TILE_SIZE)
    .height(RULE_TILE_SIZE)
    .borderRadius(RULE_TILE_SIZE / 2)
    .backgroundColor(this.appStyle.palette.brandSoft)
  }

  @Builder
  Chevron() {
    SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([$r('sys.color.icon_secondary')])
  }

  @Builder
  KindMenu() {
    Menu() {
      ForEach(KIND_GROUPS, (group: RuleKindGroup) => {
        MenuItemGroup({ header: group.label }) {
          ForEach(group.kinds, (kind: string) => {
            MenuItem({ content: kind })
              .contentFont({ family: 'monospace', size: 15 })
              .selected(kind === this.draft.kind)
              .selectIcon(true)
              .onClick((): void => this.pickKind(kind))
          }, (kind: string): string => kind)
        }
      }, (group: RuleKindGroup): string => group.id)
    }
  }

  @Builder
  RuleSetMenu() {
    Menu() {
      ForEach(this.ruleSets, (item: RuleSetItem) => {
        MenuItem({ content: item.name })
          .selected(item.id === this.draft.payloadText)
          .selectIcon(true)
          .onClick((): void => this.change((): void => { this.draft.payloadText = item.id; }))
      }, (item: RuleSetItem): string => item.id)
    }
  }

  @Builder
  KindRow() {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      Row({ space: 12 }) {
        this.Tile(KIND_GROUPS[this.groupIndex].icon, true)
        Column({ space: 2 }) {
          this.Caption($r('app.string.added_rules_type'))
          Text(this.draft.kind)
            .fontFamily('monospace')
            .fontSize(17)
            .lineHeight(24)
            .fontWeight(600)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Row({ space: 4 }) {
          Text(KIND_GROUPS[this.groupIndex].label)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
          this.Chevron()
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height(RULE_ROW_HEIGHT)
    .borderRadius(0)
    .padding(0)
    .bindMenu(this.KindMenu)
  }

  @Builder
  PayloadRow() {
    if (this.draft.kind === 'RULE-SET') {
      Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        Row({ space: 12 }) {
          this.Tile($r('sys.symbol.rectangle_stack'), false)
          Column({ space: 2 }) {
            this.Caption($r('app.string.rule_set_title'))
            Text(this.ruleSets.length === 0 ? $r('app.string.rule_set_empty') :
              this.ruleSetName !== '' ? this.ruleSetName : $r('app.string.rule_set_choose'))
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(17)
              .lineHeight(24)
              .fontWeight(this.ruleSetName !== '' ? 600 : 400)
              .fontColor(this.ruleSetName !== '' ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          if (this.ruleSets.length > 0) {
            this.Chevron()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .height(RULE_ROW_HEIGHT)
      .borderRadius(0)
      .padding(0)
      .enabled(this.ruleSets.length > 0)
      .bindMenu(this.RuleSetMenu)
    } else {
      Row({ space: 12 }) {
        this.Tile($r('sys.symbol.character_textbox'), false)
        Column({ space: 2 }) {
          this.Caption($r('app.string.added_rules_content'))
          TextInput({ text: this.draft.payloadText,
            placeholder: KIND_EXAMPLES[this.draft.kind] ?? $r('app.string.added_rules_content_hint') })
            .id(PAYLOAD_INPUT_ID)
            .fontFamily('monospace')
            .fontSize(17)
            .fontWeight(600)
            .placeholderFont({ size: 17, family: 'monospace' })
            .placeholderColor($r('sys.color.font_tertiary'))
            .caretColor(this.appStyle.palette.brand)
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .padding(0)
            .height(26)
            .maxLength(2048)
            .onChange((input: string): void => { this.draft.payloadText = input; this.onChange(); })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height(RULE_ROW_HEIGHT)
      .padding({ left: 16, right: 16 })
      // 整行都能点进输入框，不必瞄准那一行字。
      .onClick((): void => { this.getUIContext().getFocusController().requestFocus(PAYLOAD_INPUT_ID); })
    }
  }

  @Builder
  MatchCard() {
    Column() {
      this.KindRow()
      Divider().color(this.appStyle.palette.divider).margin({ left: RULE_TEXT_INSET, right: 16 })
      this.PayloadRow()
    }
    .width('100%')
    .borderRadius(RULE_CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .clip(true)
  }

  @Builder
  TargetCard() {
    Column({ space: 12 }) {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.arrow_triangle_divide')).fontSize(16).fontColor([this.appStyle.palette.brand])
        this.Caption($r('app.string.added_rules_target'))
      }
      .padding({ left: 16, right: 16 })
      // 一行横滑，抽屉高度不随策略和出口数量变化；两端渐隐提示还能继续滑。
      List({ space: 8, initialIndex: this.targetStart }) {
        ForEach(this.targetChoices, (choice: TargetChoice) => {
          ListItem() {
            RuleChip({
              label: choice.label, selected: this.chosen(choice), mono: choice.kind === 'builtin',
              tone: choice.kind === 'builtin' ? ruleTargetTone(choice.value) : 'brand',
              icon: choice.kind === 'exit' ? $r('sys.symbol.arrowshape_turn_up_right') :
                choice.kind === 'new' ? $r('sys.symbol.plus') : undefined,
              motion: this.motion, onTap: (): void => this.pickTarget(choice)
            })
          }
        }, (choice: TargetChoice): string => choice.key)
      }
      .listDirection(Axis.Horizontal)
      .width('100%')
      .height(36)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .contentStartOffset(16)
      .contentEndOffset(16)
      .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(20) })
      if (this.naming) {
        Column({ space: 6 }) {
          this.Caption($r('app.string.added_rules_exit_name'))
          TextInput({ text: this.draft.target, placeholder: $r('app.string.added_rules_exit_hint') })
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(16)
            .caretColor(this.appStyle.palette.brand)
            .backgroundColor(this.appStyle.palette.tileBackground)
            .borderRadius(14)
            .padding({ left: 14, right: 14 })
            .height(44)
            .maxLength(1024)
            .onChange((text: string): void => { this.draft.target = text; this.onChange(); })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16 })
        .transition(ruleSectionTransition(this.motion))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 16, bottom: 16 })
    .borderRadius(RULE_CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .clip(true)
  }

  @Builder
  ToggleRow(icon: Resource, label: Resource, on: boolean, apply: (on: boolean) => void) {
    Row({ space: 12 }) {
      this.Tile(icon, false)
      Text(label)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(16)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: on })
        .selectedColor(this.appStyle.palette.brand)
        .accessibilityText(label)
        .onChange((value: boolean): void => { apply(value); this.onChange(); })
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 16 })
  }

  @Builder
  ParamsCard() {
    Column() {
      this.ToggleRow($r('sys.symbol.link_slash'), $r('app.string.added_rules_no_resolve'), this.draft.noResolve,
        (on: boolean): void => { this.draft.noResolve = on; })
      Divider().color(this.appStyle.palette.divider).margin({ left: RULE_TEXT_INSET, right: 16 })
      this.ToggleRow($r('sys.symbol.arrowshape_turn_up_left'), $r('app.string.added_rules_source_ip'),
        this.draft.source, (on: boolean): void => { this.draft.source = on; })
    }
    .width('100%')
    .borderRadius(RULE_CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .clip(true)
  }

  @Builder
  Actions() {
    // 两套操作叠在同一格里交替出现，切换时不会先把高度撑成两份。
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.discardRequested) {
        Column({ space: 12 }) {
          RuleNote({ icon: $r('sys.symbol.exclamationmark_circle'), text: $r('app.string.added_rules_unsaved') })
          Row({ space: 10 }) {
            RuleSecondaryButton({ label: $r('app.string.added_rules_resume'), onPress: (): void => this.onResume() })
              .layoutWeight(1)
            RuleSecondaryButton({ label: $r('app.string.added_rules_discard'), danger: true,
              onPress: (): void => this.onDiscard() })
              .layoutWeight(1)
          }
          .width('100%')
        }
        .width('100%')
        .transition(ruleSectionTransition(this.motion))
      } else {
        Column() {
          RulePrimaryButton({ label: $r('app.string.action_save'), busy: this.saving, available: this.ready,
            onPress: (): void => this.onSave() })
        }
        .width('100%')
        .transition(ruleSectionTransition(this.motion))
      }
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Column() {
          RuleSheetHeader({ icon: this.editing ? $r('sys.symbol.square_and_pencil') : $r('sys.symbol.plus'),
            heading: this.editing ? $r('app.string.added_rules_edit') : $r('app.string.added_rules_add'),
            closable: !this.saving, onClose: (): void => this.onCancel() })
        }
        .width('100%')
        .margin({ bottom: 6 })
        .opacity(this.entered ? 1 : 0)
        .translate({ y: this.entered ? 0 : RULE_ENTER_OFFSET })
        .animation(ruleEnter(this.motion, 0))
        Column() { this.MatchCard() }
          .width('100%')
          .enabled(!this.saving)
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : RULE_ENTER_OFFSET })
          .animation(ruleEnter(this.motion, 1))
        Column() { this.TargetCard() }
          .width('100%')
          .enabled(!this.saving)
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : RULE_ENTER_OFFSET })
          .animation(ruleEnter(this.motion, 2))
        if (addedRuleHasParams(this.draft.kind)) {
          Column() { this.ParamsCard() }
            .width('100%')
            .enabled(!this.saving)
            .opacity(this.entered ? 1 : 0)
            .translate({ y: this.entered ? 0 : RULE_ENTER_OFFSET })
            .animation(ruleEnter(this.motion, 3))
            .transition(ruleSectionTransition(this.motion))
        }
        if (this.issue !== '') {
          Column() {
            RuleNote({ icon: $r('sys.symbol.exclamationmark_triangle'), text: this.issue, error: true })
          }
          .width('100%')
          .transition(ruleSectionTransition(this.motion))
        }
        Column() { this.Actions() }
          .width('100%')
          .margin({ top: 4 })
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : RULE_ENTER_OFFSET })
          .animation(ruleEnter(this.motion, 4))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 20, bottom: 24 })
    }
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .onAppear((): void => { this.entered = true; })
  }
}
