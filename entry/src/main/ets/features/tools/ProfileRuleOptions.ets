import { common } from '@kit.AbilityKit';
import { ADDED_RULE_TARGETS, AddedRule, addedRuleText, ProfileAddedRules } from '../../client/AddedRules';
import { RuleSetItem } from '../../client/RuleSets';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { EmptyState } from '../../components/EmptyState';
import { ListRow } from '../../components/ListRow';
import { ListSource } from '../../components/ListSource';
import { PAGE_GUTTER } from '../../components/Theme';
import { yamlPath } from '../../shared/profiles/Store';
import { analyze, ProfileSummary, readSummary, SummaryGroup, SummaryProxy } from '../../shared/profiles/Summary';
import { SettingsSection } from './SettingsSection';

interface MatchChoice {
  name: string;
  detail: ResourceStr;
}

@ComponentV2
export struct ProfileRuleOptions {
  @Param @Require standard: ProfileAddedRules;
  @Param globals: AddedRule[] = [];
  @Param ruleSets: RuleSetItem[] = [];
  @Param saving: boolean = false;
  @Event onChange: (value: ProfileAddedRules) => void = (_value: ProfileAddedRules): void => {};
  @Event onGlobalRules: () => void = (): void => {};
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private targetShown: boolean = false;
  @Local private globalsShown: boolean = false;
  @Local private openGlobalRules: boolean = false;
  @Local private targetLoading: boolean = false;
  @Local private targetFailed: boolean = false;
  @Local private query: string = '';
  @Local private choicesCount: number = 0;
  @Local private globalsCount: number = 0;
  private choices: MatchChoice[] = [];
  private targetRequest: number = 0;
  private targets: ListSource<MatchChoice> = new ListSource<MatchChoice>();
  private visibleGlobals: ListSource<AddedRule> = new ListSource<AddedRule>();

  private label(rule: AddedRule): string {
    return rule.kind === 'RULE-SET' ?
      this.ruleSets.find((item: RuleSetItem): boolean => item.id === rule.payload)?.name ?? rule.payload : rule.payload;
  }

  private async pickTarget(): Promise<void> {
    const request = ++this.targetRequest;
    this.query = '';
    this.targetShown = true;
    this.targetLoading = true;
    this.targetFailed = false;
    const profile = this.standard.profile;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let summary: ProfileSummary | undefined;
    let failed = false;
    try {
      summary = await readSummary(context.filesDir, profile);
      if (summary?.nodes === undefined) {
        const source = await analyze(yamlPath(context.filesDir, profile));
        if (source.error !== '') { throw new Error('profile_settings_invalid'); }
        summary = JSON.parse(source.summary) as ProfileSummary;
      }
    } catch (_error) { failed = true; }
    if (request !== this.targetRequest || !this.targetShown) { return; }
    this.targetFailed = failed;
    const candidates: MatchChoice[] = ADDED_RULE_TARGETS.filter((name: string): boolean => name !== 'MATCH')
      .map((name: string): MatchChoice => ({ name: name, detail: $r('app.string.standard_basic_target') }));
    (summary?.groups ?? []).forEach((group: SummaryGroup): void => {
      candidates.push({ name: group.name, detail: $r('app.string.standard_group_target', group.type) });
    });
    (summary?.nodes ?? []).forEach((node: SummaryProxy): void => {
      candidates.push({ name: node.name, detail: $r('app.string.standard_node_target', node.type) });
    });
    const seen = new Set<string>();
    this.choices = candidates.filter((choice: MatchChoice): boolean => {
      const name = choice.name;
      if (name === '' || name.length > 1024 || name.trim() !== name ||
        /[,\x00\r\n]/.test(name) || seen.has(name)) { return false; }
      seen.add(name);
      return true;
    });
    this.searchTargets();
    this.targetLoading = false;
  }

  private searchTargets(): void {
    const query = this.query.trim().toLowerCase();
    const result = this.choices.filter((choice: MatchChoice): boolean => choice.name.toLowerCase().includes(query));
    this.choicesCount = result.length;
    this.targets.replace(result);
  }

  private searchGlobals(): void {
    const query = this.query.trim().toLowerCase();
    const result = this.globals.filter((rule: AddedRule): boolean =>
      addedRuleText(rule, this.label(rule)).toLowerCase().includes(query));
    this.globalsCount = result.length;
    this.visibleGlobals.replace(result);
  }

  @Monitor('globals')
  globalsChanged(): void { if (this.globalsShown) { this.searchGlobals(); } }

  private saveTarget(name: string): void {
    this.targetShown = false;
    if (name !== this.standard.matchTarget) {
      this.onChange({ profile: this.standard.profile, revision: this.standard.revision, rules: this.standard.rules,
        disabled: this.standard.disabled, matchTarget: name });
    }
  }

  private toggleGlobal(id: string): void {
    const ids = this.standard.disabled;
    const disabled = ids.includes(id) ? ids.filter((item: string): boolean => item !== id) : ids.concat([id]);
    this.onChange({ profile: this.standard.profile, revision: this.standard.revision, rules: this.standard.rules,
      disabled: disabled, matchTarget: this.standard.matchTarget });
  }

  @Builder
  TargetRow(title: ResourceStr, name: string, detail: ResourceStr = '') {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(title).fontFamily(this.appStyle.fontFamily).fontSize(16)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (detail !== '') {
            Text(detail).fontSize(13).fontColor($r('sys.color.font_secondary'))
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.standard.matchTarget === name) {
          SymbolGlyph($r('sys.symbol.checkmark')).fontSize(18).fontColor([this.appStyle.palette.brand])
        }
      }.width('100%').padding({ left: 16, right: 16 })
    }.width('100%').height(56).accessibilitySelected(this.standard.matchTarget === name)
      .onClick((): void => this.saveTarget(name))
  }

  @Builder
  TargetSheet() {
    Column({ space: 8 }) {
      if (this.targetLoading) {
        LoadingProgress().width(28).height(28).color(this.appStyle.palette.brand)
      } else {
        this.TargetRow($r('app.string.standard_follow_profile'), '')
        if (this.targetFailed) {
          ListRow({ title: $r('app.string.standard_target_load_failed'), onTap: (): void => { this.pickTarget(); } })
        }
        TextInput({ text: this.query, placeholder: $r('app.string.diagnostics_search') }).height(40)
          .onChange((text: string): void => { this.query = text; this.searchTargets(); })
        if (this.choicesCount === 0) {
          EmptyState({ icon: $r('sys.symbol.magnifyingglass'), title: $r('app.string.diagnostics_no_matches') })
            .layoutWeight(1)
        } else {
          List() {
            LazyForEach(this.targets, (choice: MatchChoice) => {
              ListItem() { this.TargetRow(choice.name, choice.name, choice.detail) }
            }, (choice: MatchChoice): string => choice.name)
          }.width('100%').layoutWeight(1).scrollBar(BarState.Off).cachedCount(2)
        }
      }
    }.width('100%').height('100%').enabled(!this.saving).padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12 })
  }

  @Builder
  GlobalSheet() {
    Column({ space: 8 }) {
      TextInput({ text: this.query, placeholder: $r('app.string.added_rules_search_hint') }).height(40)
        .onChange((text: string): void => { this.query = text; this.searchGlobals(); })
      if (this.globalsCount === 0) {
        EmptyState({ icon: $r('sys.symbol.list_bullet'),
          title: this.query.trim() === '' ? $r('app.string.added_rules_empty') :
            $r('app.string.diagnostics_no_matches') }).layoutWeight(1)
      } else {
        List() {
          LazyForEach(this.visibleGlobals, (rule: AddedRule) => {
            ListItem() {
              Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
                Row({ space: 12 }) {
                  Text(addedRuleText(rule, this.label(rule))).fontFamily('monospace').fontSize(14).maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                  SymbolGlyph(this.standard.disabled.includes(rule.id) ?
                    $r('sys.symbol.circle') : $r('sys.symbol.checkmark_circle_fill'))
                    .fontSize(20).fontColor([this.standard.disabled.includes(rule.id) ?
                      $r('sys.color.font_secondary') : this.appStyle.palette.brand])
                }.width('100%')
              }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 12, right: 12 })
                .accessibilitySelected(!this.standard.disabled.includes(rule.id))
                .onClick((): void => this.toggleGlobal(rule.id))
            }
          }, (rule: AddedRule): string => rule.id)
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off).cachedCount(2)
      }
      Button($r('app.string.script_go_to_rules')).height(42).onClick((): void => {
        this.openGlobalRules = true;
        this.globalsShown = false;
      })
    }.width('100%').height('100%').enabled(!this.saving)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 20 })
  }

  @Builder
  Options() {
    ListRow({ title: $r('app.string.standard_match_target'),
      value: this.standard.matchTarget || $r('app.string.standard_follow_profile'),
      onTap: (): void => { this.pickTarget(); } })
    Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
    ListRow({ title: $r('app.string.standard_global_rules'), onTap: (): void => {
      this.query = '';
      this.searchGlobals();
      this.globalsShown = true;
    } })
  }

  build() {
    Column() {
      SettingsSection({ rows: (): void => this.Options() }).enabled(!this.saving)
      Column().bindSheet($$this.targetShown, this.TargetSheet, {
        title: { title: $r('app.string.standard_match_target') }, height: SheetSize.LARGE,
        showClose: true, systemMaterial: this.appStyle.sheetMaterial()
      })
      Column().bindSheet($$this.globalsShown, this.GlobalSheet, {
        title: { title: $r('app.string.standard_global_rules') }, height: SheetSize.LARGE,
        showClose: true, systemMaterial: this.appStyle.sheetMaterial(),
        onWillDismiss: (action: DismissSheetAction): void => { if (!this.saving) { action.dismiss(); } },
        onDisappear: (): void => {
          if (this.openGlobalRules) { this.openGlobalRules = false; this.onGlobalRules(); }
        }
      })
    }.width('100%')
  }
}
