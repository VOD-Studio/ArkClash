import { AddedRule, ADDED_RULE_KINDS, ADDED_RULE_TARGETS, addedRuleHasParams } from '../../client/AddedRules';
import { RuleSetItem } from '../../client/RuleSets';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { SettingsSection } from './SettingsSection';

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

const RULE_KIND_OPTIONS: SelectOption[] = ADDED_RULE_KINDS.map((kind: string): SelectOption => ({ value: kind }));
const RULE_TARGET_OPTIONS: SelectOption[] = ADDED_RULE_TARGETS.map((target: string): SelectOption =>
  ({ value: target === 'MATCH' ? 'MATCH-TARGET' : target }));

@ComponentV2
export struct AddedRuleEditor {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require draft: AddedRuleDraft;
  @Param saving: boolean = false;
  @Param discardRequested: boolean = false;
  @Param issue: ResourceStr = '';
  @Param ruleSets: RuleSetItem[] = [];
  @Param ruleSetOptions: SelectOption[] = [];
  @Param knownExits: string[] = [];
  @Event onSave: () => void = () => {};
  @Event onCancel: () => void = () => {};
  @Event onDiscard: () => void = () => {};
  @Event onResume: () => void = () => {};
  @Event onChange: () => void = () => {};

  @Builder
  Label(label: ResourceStr) {
    Text(label).fontFamily(this.appStyle.fontFamily).fontSize(16).fontColor($r('sys.color.font_primary'))
  }

  @Builder
  RuleDivider() {
    Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
  }

  private ruleSetIndex(): number {
    return this.ruleSets.findIndex((item: RuleSetItem): boolean => item.id === this.draft.payloadText);
  }

  @Computed
  get targetOptions(): SelectOption[] {
    return RULE_TARGET_OPTIONS.concat(this.knownExits.map((name: string): SelectOption => ({
      value: $r('app.string.added_rules_exit_option', name)
    })), [{ value: $r('app.string.added_rules_exit_new') }]);
  }

  private pickRuleTarget(index: number): void {
    this.draft.customExit = index >= ADDED_RULE_TARGETS.length;
    this.draft.target = this.draft.customExit ? this.knownExits[index - ADDED_RULE_TARGETS.length] ?? '' :
      ADDED_RULE_TARGETS[index] ?? 'DIRECT';
    this.onChange();
  }

  private targetIndex(): number {
    if (!this.draft.customExit) { return ADDED_RULE_TARGETS.indexOf(this.draft.target); }
    const index = this.knownExits.indexOf(this.draft.target);
    return ADDED_RULE_TARGETS.length + (index < 0 ? this.knownExits.length : index);
  }

  @Builder
  BasicRows() {
    Row({ space: 12 }) {
      this.Label($r('app.string.added_rules_type'))
      Blank()
      Select(RULE_KIND_OPTIONS)
        .selected(Math.max(0, ADDED_RULE_KINDS.indexOf(this.draft.kind)))
        .value(this.draft.kind)
        .onSelect((index: number): void => {
          const next = ADDED_RULE_KINDS[index] ?? this.draft.kind;
          if (next !== this.draft.kind && (next === 'RULE-SET' || this.draft.kind === 'RULE-SET')) {
            this.draft.payloadText = '';
          }
          this.draft.kind = next;
          this.onChange();
        })
    }
    .width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12 })
    this.RuleDivider()
    Row({ space: 12 }) {
      if (this.draft.kind === 'RULE-SET') {
        this.Label($r('app.string.rule_set_title'))
        Blank()
        if (this.ruleSets.length === 0) {
          Text($r('app.string.rule_set_empty')).fontSize(14).fontColor($r('sys.color.font_secondary'))
        } else {
          Select(this.ruleSetOptions).selected(this.ruleSetIndex())
            .value(this.ruleSets[this.ruleSetIndex()]?.name ?? $r('app.string.rule_set_choose'))
            .onSelect((index: number): void => {
              this.draft.payloadText = this.ruleSets[index]?.id ?? '';
              this.onChange();
            })
        }
      } else {
        this.Label($r('app.string.added_rules_content'))
        TextInput({ text: this.draft.payloadText, placeholder: $r('app.string.added_rules_content_hint') })
          .layoutWeight(1)
          .textAlign(TextAlign.End)
          .height(44)
          .maxLength(2048)
          .backgroundColor(Color.Transparent)
          .onChange((input: string): void => { this.draft.payloadText = input; this.onChange(); })
      }
    }
    .width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12 })
    this.RuleDivider()
    Row({ space: 12 }) {
      this.Label($r('app.string.added_rules_target'))
      Blank()
      Select(this.targetOptions)
        .selected(this.targetIndex())
        .value(this.draft.customExit ? this.draft.target || $r('app.string.added_rules_exit_new') :
          this.draft.target === 'MATCH' ? 'MATCH-TARGET' : this.draft.target)
        .onSelect((index: number): void => this.pickRuleTarget(index))
    }
    .width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12 })
    if (this.draft.customExit) {
      this.RuleDivider()
      Row({ space: 12 }) {
        this.Label($r('app.string.added_rules_exit_name'))
        TextInput({ text: this.draft.target, placeholder: $r('app.string.added_rules_exit_hint') })
          .layoutWeight(1).textAlign(TextAlign.End).height(44).maxLength(1024)
          .backgroundColor(Color.Transparent)
          .onChange((text: string): void => { this.draft.target = text; this.onChange(); })
      }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 12 })
    }
  }

  @Builder
  ParamsRows() {
    Row() {
      this.Label($r('app.string.added_rules_no_resolve'))
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: this.draft.noResolve })
        .selectedColor(this.appStyle.palette.brand)
        .accessibilityText($r('app.string.added_rules_no_resolve'))
        .onChange((on: boolean): void => { this.draft.noResolve = on; this.onChange(); })
    }
    .width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16 })
    this.RuleDivider()
    Row() {
      this.Label($r('app.string.added_rules_source_ip'))
      Blank()
      Toggle({ type: ToggleType.Switch, isOn: this.draft.source })
        .selectedColor(this.appStyle.palette.brand)
        .accessibilityText($r('app.string.added_rules_source_ip'))
        .onChange((on: boolean): void => { this.draft.source = on; this.onChange(); })
    }
    .width('100%').constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16 })
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        SettingsSection({
          heading: $r('app.string.added_rules_basic'),
          rows: (): void => this.BasicRows()
        })
        if (addedRuleHasParams(this.draft.kind)) {
          SettingsSection({
            heading: $r('app.string.added_rules_params'),
            rows: (): void => this.ParamsRows()
          })
        }
        if (this.issue !== '') {
          Text(this.issue).fontFamily(this.appStyle.fontFamily).fontSize(14).fontColor($r('app.color.status_error'))
        }
        if (this.discardRequested) {
          Text($r('app.string.added_rules_unsaved')).fontSize(14).fontColor($r('sys.color.font_secondary'))
          Row({ space: 12 }) {
            Button($r('app.string.added_rules_resume')).buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1)
              .onClick((): void => this.onResume())
            Button($r('app.string.added_rules_discard')).role(ButtonRole.ERROR).layoutWeight(1)
              .onClick((): void => this.onDiscard())
          }
          .width('100%')
        } else {
          Row({ space: 12 }) {
            Button($r('app.string.action_cancel')).buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1)
              .onClick((): void => this.onCancel())
            Button($r('app.string.action_save')).layoutWeight(1).onClick((): void => this.onSave())
          }
          .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .enabled(!this.saving)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
  }
}
