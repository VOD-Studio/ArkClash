import { ScrollControls } from '../../components/ScrollControls';
import { common } from '@kit.AbilityKit';
import { AddedRule, AddedRulesSettings, ProfileAddedRules, profileAddedRules, addedRuleText, emptyAddedRules, newAddedRule, readAddedRules,
  namedExits, saveAddedRules, validAddedRule, validExitName } from '../../client/AddedRules';
import { readRuleSets, RuleSetItem } from '../../client/RuleSets';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ScrollDestination } from '../../components/ScrollDestination';
import { KeyedListSource } from '../../components/KeyedListSource';
import { HEADER_ACTION, HEADER_ICON_SIZE, HEADER_GAP, PAGE_GUTTER } from '../../components/Theme';
import { AddedRuleDraft, AddedRuleEditor } from './AddedRuleEditor';
import { AddedRulePresets } from './AddedRulePresets';
import { AddedRulesEmpty } from './AddedRulesEmpty';
import { ProfileRuleOptions } from './ProfileRuleOptions';

class AddedRuleListItem {
  readonly key: string;
  readonly rule: AddedRule;
  readonly label: string;

  constructor(rule: AddedRule, label: string) {
    this.key = rule.id;
    this.rule = rule;
    this.label = label;
  }
}

let cachedAddedRules: AddedRulesSettings | undefined = undefined;
let cachedAddedRuleSets: RuleSetItem[] | undefined = undefined;

@ComponentV2
export struct AddedRulesPage {
  @Param foreground: boolean = true;
  @Param reduceMotion: boolean = true;
  @Param profileId: string = '';
  @Event onGlobalRules: () => void = (): void => {};
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private settings: AddedRulesSettings = cachedAddedRules ?? emptyAddedRules();
  @Local private loading: boolean = cachedAddedRules === undefined;
  @Local private loadFailed: boolean = false;
  @Local private saving: boolean = false;
  @Local private query: string = '';
  @Local private searchShown: boolean = false;
  @Local private selecting: boolean = false;
  @Local private selectedIds: string[] = [];
  @Local private visibleIds: string[] = [];
  @Local private visibleCount: number = 0;
  @Local private firstId: string = '';
  @Local private lastId: string = '';
  @Local private draft?: AddedRuleDraft;
  @Local private editingExisting: boolean = false;
  @Local private editShown: boolean = false;
  @Local private presetsShown: boolean = false;
  @Local private presetExisting: string[] = [];
  @Local private deleteShown: boolean = false;
  @Local private discardRequested: boolean = false;
  @Local private editIssue: ResourceStr = '';
  @Local private ruleSets: RuleSetItem[] = cachedAddedRuleSets ?? [];
  private shown: boolean = false;
  private rows: KeyedListSource<AddedRuleListItem> = new KeyedListSource<AddedRuleListItem>();

  aboutToAppear(): void {
    if (cachedAddedRules !== undefined) {
      this.refreshRows();
    }
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private standard(): ProfileAddedRules { return profileAddedRules(this.settings, this.profileId); }

  private rules(): AddedRule[] { return this.profileId === '' ? this.settings.rules : this.standard().rules; }

  private toast(message: ResourceStr): void {
    if (this.shown && this.foreground) {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private async load(): Promise<void> {
    const silent = cachedAddedRules !== undefined;
    if (!silent) {
      this.loading = true;
    }
    try {
      const settings = await readAddedRules(this.context().filesDir);
      const catalog = await readRuleSets(this.context().filesDir).catch((): undefined => undefined);
      cachedAddedRules = settings;
      this.settings = settings;
      if (catalog !== undefined) {
        cachedAddedRuleSets = catalog.items;
        this.ruleSets = catalog.items;
      } else if (cachedAddedRuleSets === undefined) {
        this.ruleSets = [];
      }
      this.refreshRows();
      this.loadFailed = false;
    } catch (_error) {
      if (!silent) {
        this.loadFailed = true;
      }
    } finally {
      this.loading = false;
    }
  }

  private refreshRows(animate: boolean = false): void {
    const words = this.query.trim().toLowerCase().split(/\s+/).filter((word: string): boolean => word !== '');
    const rows: AddedRuleListItem[] = [];
    for (const rule of this.rules()) {
      const label = rule.kind === 'RULE-SET' ?
        this.ruleSets.find((item: RuleSetItem): boolean => item.id === rule.payload)?.name ?? rule.payload : rule.payload;
      const text = addedRuleText(rule, label).toLowerCase();
      if (words.every((word: string): boolean => text.includes(word))) {
        rows.push(new AddedRuleListItem(rule, label));
      }
    }
    this.visibleCount = rows.length;
    this.visibleIds = rows.map((row: AddedRuleListItem): string => row.key);
    this.firstId = rows[0]?.key ?? '';
    this.lastId = rows[rows.length - 1]?.key ?? '';
    this.rows.replace(rows, animate && this.shown && this.foreground && !this.reduceMotion ?
      (apply: () => void): void => this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, apply) :
      undefined);
  }

  private updateSearch(value: string): void {
    this.query = value;
    this.refreshRows();
  }

  private toggleSearch(): void {
    this.searchShown = !this.searchShown;
    if (!this.searchShown) {
      this.updateSearch('');
    }
  }

  private openEdit(rule?: AddedRule): void {
    if (this.saving || this.loading || this.loadFailed) {
      return;
    }
    this.editingExisting = rule !== undefined;
    this.draft = new AddedRuleDraft(rule ?? newAddedRule());
    this.editIssue = '';
    this.discardRequested = false;
    this.editShown = true;
  }

  private openPresets(): void {
    if (this.saving || this.loading || this.loadFailed) {
      return;
    }
    // 打开时取一次快照；抽屉开着时列表只会被这个抽屉自己改，改完即关闭。
    this.presetExisting = this.rules().map((rule: AddedRule): string => addedRuleText(rule));
    this.presetsShown = true;
  }

  private requestCloseEditor(dismiss: () => void): void {
    if (this.saving) {
      return;
    }
    if (this.draft?.dirty() === true) {
      this.discardRequested = true;
    } else {
      dismiss();
    }
  }

  private saveDraft(): void {
    const draft = this.draft;
    if (draft === undefined) {
      return;
    }
    const rule = draft.rule();
    if (rule.kind === 'RULE-SET' && !this.ruleSets.some((item: RuleSetItem): boolean => item.id === rule.payload)) {
      this.editIssue = $r('app.string.rule_set_choose');
      return;
    }
    if (rule.customExit === true && !validExitName(rule.target)) {
      this.editIssue = $r('app.string.added_rules_exit_invalid');
      return;
    }
    if (!validAddedRule(rule)) {
      this.editIssue = $r('app.string.added_rules_invalid');
      return;
    }
    if (this.editingExisting && !draft.dirty()) {
      this.editShown = false;
      return;
    }
    const next = this.rules().slice();
    const index = next.findIndex((item: AddedRule): boolean => item.id === rule.id);
    if (index === -1) {
      if (this.editingExisting) {
        this.editIssue = $r('app.string.added_rules_conflict');
        return;
      }
      next.unshift(rule);
    } else {
      next[index] = rule;
    }
    this.commit(next);
  }

  private async commit(rules: AddedRule[], reordering: boolean = false, standard: ProfileAddedRules = this.standard()):
    Promise<void> {
    if (this.saving) {
      return;
    }
    const previous = this.settings;
    this.saving = true;
    const update: ProfileAddedRules | undefined = this.profileId === '' ? undefined : {
      profile: standard.profile, revision: standard.revision, rules: rules,
      disabled: standard.disabled, matchTarget: standard.matchTarget, exitTargets: standard.exitTargets
    };
    if (reordering) {
      this.settings = { revision: previous.revision, rules: update === undefined ? rules : previous.rules,
        profiles: previous.profiles?.map((item: ProfileAddedRules): ProfileAddedRules =>
          item.profile === update?.profile ? update : item) };
      this.refreshRows();
    }
    try {
      this.settings = await saveAddedRules(this.context(), previous, update === undefined ? rules : previous.rules, update);
      cachedAddedRules = this.settings;
      this.refreshRows(!reordering);
      this.editShown = false;
      this.presetsShown = false;
      if (this.deleteShown) {
        const remaining = new Set<string>(this.rules().map((rule: AddedRule): string => rule.id));
        this.selectedIds = this.selectedIds.filter((id: string): boolean => remaining.has(id));
        this.selecting = this.selectedIds.length > 0;
        this.deleteShown = false;
      }
      this.toast($r('app.string.added_rules_saved'));
    } catch (error) {
      this.settings = previous;
      this.refreshRows();
      const reason = (error as Error).message;
      const message = this.failureText(reason);
      if (reason === 'profile_settings_conflict') {
        await this.load();
        this.clearSelection();
        this.deleteShown = false;
      }
      if (this.editShown) {
        this.editIssue = message;
      } else {
        this.toast(message);
      }
    } finally {
      this.saving = false;
    }
  }

  private failureText(reason: string): Resource {
    switch (reason) {
      case 'profile_settings_invalid': return $r('app.string.added_rules_invalid');
      case 'profile_settings_conflict': return $r('app.string.added_rules_conflict');
      case 'profile_settings_unavailable': return $r('app.string.added_rules_unavailable');
      case 'added_rules_match_target': return $r('app.string.standard_match_target_missing');
      case 'rule_set_in_use': return $r('app.string.rule_set_choose');
      default: return $r('app.string.added_rules_save_failed');
    }
  }

  private addPresets(rules: AddedRule[]): void {
    const existing = new Set<string>(this.rules().map((item: AddedRule): string => addedRuleText(item)));
    const added = rules.filter((rule: AddedRule): boolean => !existing.has(addedRuleText(rule)));
    if (added.length === 0) {
      this.presetsShown = false;
      return;
    }
    this.commit(added.concat(this.rules()));
  }

  private clearSelection(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  private toggleRow(rule: AddedRule): void {
    if (!this.selecting) {
      this.openEdit(rule);
      return;
    }
    this.selectedIds = this.selectedIds.includes(rule.id) ?
      this.selectedIds.filter((id: string): boolean => id !== rule.id) : this.selectedIds.concat([rule.id]);
  }

  private selectVisible(): void {
    const selected = new Set<string>(this.selectedIds);
    const all = this.visibleIds.every((id: string): boolean => selected.has(id));
    for (const id of this.visibleIds) {
      if (all) { selected.delete(id); } else { selected.add(id); }
    }
    this.selectedIds = Array.from(selected);
  }

  private selectedVisible(): string[] {
    const selected = new Set<string>(this.selectedIds);
    return this.visibleIds.filter((id: string): boolean => selected.has(id));
  }

  private deleteSelected(): void {
    const selected = new Set<string>(this.selectedVisible());
    this.commit(this.rules().filter((rule: AddedRule): boolean => !selected.has(rule.id)));
  }

  private reorder(from: number, to: number): void {
    if (this.selecting || this.query.trim() !== '' || this.saving) {
      return;
    }
    const rules = this.rules().slice();
    if (from === to || from < 0 || to < 0 || from >= rules.length || to >= rules.length) {
      return;
    }
    const moved = rules.splice(from, 1)[0];
    rules.splice(to, 0, moved);
    this.commit(rules, true);
  }

  private handleBack(): boolean {
    if (this.saving) { return true; }
    if (this.selecting) {
      this.clearSelection();
      return true;
    }
    if (this.searchShown) {
      this.toggleSearch();
      return true;
    }
    return false;
  }

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: this.profileId === '' ? $r('app.string.added_rules_title') :
      $r('app.string.standard_rules_title') })
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      if (this.selecting) {
        AddedRuleHeaderButton({ icon: $r('sys.symbol.xmark'), label: $r('app.string.action_cancel'),
          available: !this.saving, onPress: (): void => this.clearSelection() })
        AddedRuleHeaderButton({ icon: $r('sys.symbol.checkmark'), label: $r('app.string.added_rules_select_all'),
          available: !this.saving && this.visibleCount > 0, onPress: (): void => this.selectVisible() })
        AddedRuleHeaderButton({ icon: $r('sys.symbol.trash'), label: $r('app.string.action_delete'),
          available: !this.saving && this.selectedVisible().length > 0, onPress: (): void => { this.deleteShown = true; } })
      } else {
        AddedRuleHeaderButton({ icon: $r('sys.symbol.magnifyingglass'), label: $r('app.string.diagnostics_search'),
          available: !this.loading && !this.loadFailed, onPress: (): void => this.toggleSearch() })
        if (this.rules().length > 0) {
          AddedRuleHeaderButton({ icon: $r('sys.symbol.checkmark'), label: $r('app.string.added_rules_select'),
            available: !this.saving, onPress: (): void => { this.selecting = true; } })
        }
        AddedRuleHeaderButton({ icon: $r('sys.symbol.bolt'), label: $r('app.string.added_rules_presets'),
          available: !this.loading && !this.loadFailed && !this.saving, onPress: (): void => this.openPresets() })
        AddedRuleHeaderButton({ icon: $r('sys.symbol.plus'), label: $r('app.string.action_add'),
          available: !this.loading && !this.loadFailed && !this.saving, onPress: (): void => this.openEdit() })
      }
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ right: PAGE_GUTTER })
  }

  @Builder
  RuleList() {
    List() {
      LazyForEach(this.rows, (item: AddedRuleListItem) => {
        ListItem() {
          AddedRuleRow({
            rule: item.rule, payloadLabel: item.label, first: item.key === this.firstId, last: item.key === this.lastId,
            selecting: this.selecting, selected: this.selectedIds.includes(item.key),
            onTap: (): void => this.toggleRow(item.rule)
          })
        }
      }, (item: AddedRuleListItem): string => item.key)
        .onMove(!this.selecting && !this.saving && this.query.trim() === '' ?
          (from: number, to: number): void => this.reorder(from, to) : undefined)
    }
    .width('100%')
    .layoutWeight(1)
    .enabled(!this.saving)
    .scrollBar(BarState.Off)
    .cachedCount(2, true)
    .clipContent(ContentClipMode.SAFE_AREA)
    .contentStartOffset(12)
    .contentEndOffset(24)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }

  @Builder
  DeleteSheet() {
    Column({ space: 16 }) {
      Text($r('app.string.added_rules_delete_count', this.selectedVisible().length))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(16)
        .width('100%')
      Row({ space: 12 }) {
        Button($r('app.string.action_cancel')).buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1)
          .onClick((): void => { this.deleteShown = false; })
        Button($r('app.string.action_delete')).role(ButtonRole.ERROR).layoutWeight(1)
          .onClick((): void => this.deleteSelected())
      }
      .width('100%')
    }
    .width('100%').enabled(!this.saving)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
  }

  @Builder
  EditorSheet() {
    if (this.draft !== undefined) {
      AddedRuleEditor({
        draft: this.draft, editing: this.editingExisting, saving: this.saving, issue: this.editIssue,
        discardRequested: this.discardRequested, ruleSets: this.ruleSets, motion: !this.reduceMotion,
        knownExits: namedExits(this.settings.rules.concat(this.standard().rules)),
        onSave: (): void => this.saveDraft(), onChange: (): void => { this.editIssue = ''; },
        onCancel: (): void => this.requestCloseEditor((): void => { this.editShown = false; }),
        onResume: (): void => { this.discardRequested = false; },
        onDiscard: (): void => { this.editShown = false; }
      })
    }
  }

  @Builder
  PresetsSheet() {
    AddedRulePresets({ saving: this.saving, existing: this.presetExisting, motion: !this.reduceMotion,
      onAdd: (rules: AddedRule[]): void => this.addPresets(rules),
      onClose: (): void => { if (!this.saving) { this.presetsShown = false; } } })
  }

  @Builder
  FilterControls() {
    if (this.profileId !== '' && !this.loading && !this.loadFailed) {
      ProfileRuleOptions({ standard: this.standard(), globals: this.settings.rules,
        ruleSets: this.ruleSets, saving: this.saving, onGlobalRules: (): void => this.onGlobalRules(),
        onChange: (next: ProfileAddedRules): void => { this.commit(next.rules, false, next); } })
        .margin({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12 })
    }
    if (this.searchShown) {
      TextInput({ text: this.query, placeholder: $r('app.string.added_rules_search_hint') })
        .height(40)
        .margin({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8 })
        .onChange((value: string): void => this.updateSearch(value))
    }
  }

  @Builder
  Content() {
    ScrollControls({ controls: (): void => this.FilterControls() }) {
      if (this.loading) {
        Column() {
          LoadingProgress().width(32).height(32).color(this.appStyle.palette.brand)
        }
        .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.loadFailed || this.visibleCount === 0) {
        AddedRulesEmpty({
          kind: this.loadFailed ? 'failed' : this.query.trim() === '' ? 'empty' : 'noMatch',
          motion: !this.reduceMotion && this.foreground, available: !this.saving,
          onAdd: (): void => this.openEdit(), onPresets: (): void => this.openPresets(),
          onRetry: (): void => { this.load(); }
        })
        .layoutWeight(1)
      } else {
        this.RuleList()
      }
    }
  }

  build() {
    ScrollDestination({
      heading: (): void => this.HeaderTitle(),
      actions: (): void => this.HeaderMenus(),
      pageShown: (): void => { this.shown = true; if (!this.saving) { this.load(); } },
      pageHidden: (): void => { this.shown = false; },
      handleBack: (): boolean => this.handleBack()
    }) {
      Stack() {
        this.Content()
        Column()
          // 两个抽屉的标题区和关闭按钮由内容自己绘制。编辑抽屉高度跟随内容，约占半屏；
          // 预设列表超过一屏，直接用大尺寸，按钮固定在底部。
          .bindSheet($$this.editShown, this.EditorSheet, {
            height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM,
            // 键盘弹起时整个抽屉抬到键盘上方并压缩高度，保存按钮滚动可达，不被键盘挡住。
            keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_RESIZE,
            systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
            onWillDismiss: (action: DismissSheetAction): void =>
              this.requestCloseEditor((): void => action.dismiss())
          })
        Column()
          .bindSheet($$this.presetsShown, this.PresetsSheet, {
            height: SheetSize.LARGE, preferType: SheetType.BOTTOM,
            systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
            onWillDismiss: (action: DismissSheetAction): void => { if (!this.saving) { action.dismiss(); } }
          })
        Column()
          .bindSheet($$this.deleteShown, this.DeleteSheet, {
            title: { title: $r('app.string.action_delete') }, height: SheetSize.FIT_CONTENT,
            systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
            onWillDismiss: (action: DismissSheetAction): void => { if (!this.saving) { action.dismiss(); } }
          })
      }
      .width('100%').height('100%')
    }
  }
}

@ComponentV2
struct AddedRuleHeaderButton {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require icon: Resource;
  @Param @Require label: Resource;
  @Param available: boolean = true;
  @Event onPress: () => void = (): void => {};

  build() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(this.icon).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
    }
    .attributeModifier(HEADER_ACTION)
    .systemMaterial(this.appStyle.headerMaterial())
    .accessibilityText(this.label)
    .enabled(this.available)
    .onClick((): void => this.onPress())
  }
}

@ComponentV2
@ReusableV2
struct AddedRuleRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require rule: AddedRule;
  @Param payloadLabel: string = '';
  @Param first: boolean = false;
  @Param last: boolean = false;
  @Param selecting: boolean = false;
  @Param selected: boolean = false;
  @Event onTap: () => void = () => {};

  private targetColor(): ResourceColor {
    if (this.rule.target === 'DIRECT' || this.rule.target === 'COMPATIBLE') {
      return $r('app.color.status_connected');
    }
    return this.rule.target.startsWith('REJECT') ? $r('app.color.status_error') : $r('sys.color.font_secondary');
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        if (this.selecting) {
          SymbolGlyph(this.selected ? $r('sys.symbol.checkmark') : $r('sys.symbol.circle'))
            .fontSize(18)
            .fontColor([this.selected ? this.appStyle.palette.brand : $r('sys.color.font_tertiary')])
            .width(24)
        }
        Column({ space: 2 }) {
          Text(this.rule.kind).fontFamily('monospace').fontSize(15).fontColor($r('sys.color.font_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.payloadLabel).fontFamily('monospace').fontSize(12).fontColor($r('sys.color.font_secondary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.rule.target === 'MATCH' ? 'MATCH-TARGET' : this.rule.target)
          .fontFamily('monospace').fontSize(14).fontColor(this.targetColor())
          .constraintSize({ maxWidth: '50%' }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%').constraintSize({ minHeight: 52 })
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
      if (!this.last) {
        Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
      }
    }
    .width('100%')
    .borderRadius({ topLeft: this.first ? 24 : 0, topRight: this.first ? 24 : 0,
      bottomLeft: this.last ? 24 : 0, bottomRight: this.last ? 24 : 0 })
    .backgroundColor(this.selected ? this.appStyle.palette.tileBackground : this.appStyle.palette.cardBackground)
    .accessibilitySelected(this.selected)
    .onClick((): void => this.onTap())
  }
}
