import { common } from '@kit.AbilityKit';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { ListSource } from '../../components/ListSource';
import { PAGE_GUTTER } from '../../components/Theme';
import {
  CUSTOM_BUILTINS, CUSTOM_EMPTY_YAML, CUSTOM_GROUP_TYPES, CUSTOM_RULE_TYPES, CustomGroup, CustomIssue,
  CustomNode, CustomProfileMutation, CustomProfileView, customRuleAllowsComma, customRuleParts
} from '../../shared/profiles/CustomProfileYaml';
import { applyCustomGroupFilter, inspectCustomProfile, readCustomSection, serializeCustomProfile } from '../../shared/profiles/CustomProfileWorker';
import { errorString } from '../../shared/profiles/Errors';
import { LocalProxy } from '../../shared/profiles/LocalProxies';
import { proxyText } from '../../shared/profiles/LocalProxySchema';
import { readLocalProxies } from '../../shared/profiles/LocalProxyStore';
import { readProxyFilters } from '../../shared/profiles/ProxyFilters';
import { ProxyFilterPreset } from '../../shared/profiles/ProxyFilterModel';
import { CustomChoice, CustomProfileChoice } from './CustomProfileChoice';
import { confirmCustomDismiss, CustomProfileDraft } from './CustomProfileDraft';
import { describeError } from './ProfileErrors';
import { ProfileStore } from './Profiles';
import { ProfileSheetHeader } from './ProfileSheetHeader';
import { uiResourceText } from '../../components/ResourceText';
import { YamlCodeEditor, YamlCodeEditorController } from './YamlCodeEditor';

type CustomPanel = 'overview' | 'groups' | 'group' | 'rules' | 'rule' | 'nodes' | 'text' | 'import' | 'issues';
type CustomPicker = 'members' | 'providers' | 'node' | 'dialer' | 'ruleTarget' | 'ruleProvider' | 'filter';

interface CustomEditorRow {
  key: string;
  index: number;
  label: ResourceStr;
  detail: ResourceStr;
}

const GROUP_OPTIONS: SelectOption[] = CUSTOM_GROUP_TYPES.map((type: string): SelectOption => ({ value: type }));
const RULE_OPTIONS: SelectOption[] = CUSTOM_RULE_TYPES.map((type: string): SelectOption => ({ value: type }));

function customFailure(error: Object): ResourceStr {
  const code = (error as Error).message ?? '';
  if (code === 'custom_shape') { return $r('app.string.custom_invalid_shape'); }
  return describeError(errorString(error));
}

export function customIssueLabel(problem: CustomIssue): ResourceStr {
  switch (problem.code) {
    case 'name': return $r('app.string.custom_issue_name', problem.subject);
    case 'duplicate': return $r('app.string.custom_issue_duplicate', problem.subject);
    case 'type': return $r('app.string.custom_issue_type', problem.subject, problem.reference);
    case 'empty_group': return $r('app.string.custom_issue_empty_group', problem.subject);
    case 'missing_target': return $r('app.string.custom_issue_target', problem.subject, problem.reference);
    case 'missing_provider': return $r('app.string.custom_issue_provider', problem.subject, problem.reference);
    case 'fallback': return $r('app.string.custom_issue_fallback', problem.subject, problem.reference);
    case 'cycle': return $r('app.string.custom_issue_cycle', problem.subject);
    case 'rule': return $r('app.string.custom_issue_rule', problem.subject);
    case 'missing_rule_provider': return $r('app.string.custom_issue_rule_provider', problem.subject, problem.reference);
    case 'missing_sub_rule': return $r('app.string.custom_issue_sub_rule', problem.subject, problem.reference);
    default: return problem.subject;
  }
}

function toNames(text: string): string[] {
  const values = text.split('\n').map((name: string): string => name.trim()).filter((name: string): boolean => name !== '');
  return Array.from(new Set<string>(values));
}

function asChoice(name: string): CustomChoice { return { key: name, label: name, detail: '' }; }

@ComponentV2
@ReusableV2
struct CustomProfileRow {
  @Local private style: AppearanceState = appAppearance;
  @Param @Require entry: CustomEditorRow;
  @Param ordered: boolean = false;
  @Param removable: boolean = false;
  @Param last: boolean = false;
  @Param controlsEnabled: boolean = true;
  @Event onOpen: () => void = (): void => {};
  @Event onMove: (offset: number) => void = (_offset: number): void => {};
  @Event onDelete: () => void = (): void => {};

  @Builder
  IconAction(icon: Resource, label: ResourceStr, enabled: boolean, action: () => void) {
    Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      SymbolGlyph(icon).fontSize(17).fontColor([$r('sys.color.font_secondary')])
    }.width(40).height(40).enabled(enabled).accessibilityText(uiResourceText(this.getUIContext(), label)).onClick(action)
  }

  build() {
    Row({ space: 2 }) {
      Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
        Column({ space: 2 }) {
          Text(this.entry.label).fontSize(16).fontFamily(this.style.fontFamily)
            .fontColor($r('sys.color.font_primary')).width('100%')
          if (this.entry.detail !== '') {
            Text(this.entry.detail).fontSize(13).fontFamily(this.style.fontFamily)
              .fontColor($r('sys.color.font_secondary')).width('100%')
          }
        }.alignItems(HorizontalAlign.Start).padding({ left: 16, right: 12, top: 8, bottom: 8 }).width('100%')
      }.layoutWeight(1).constraintSize({ minHeight: 56 })
      .accessibilityText(uiResourceText(this.getUIContext(), this.entry.label)).onClick((): void => this.onOpen())
      if (this.ordered) {
        this.IconAction($r('sys.symbol.chevron_up'), $r('app.string.custom_move_up'),
          this.controlsEnabled && this.entry.index > 0, (): void => this.onMove(-1))
        this.IconAction($r('sys.symbol.chevron_down'), $r('app.string.custom_move_down'),
          this.controlsEnabled && !this.last, (): void => this.onMove(1))
      }
      if (this.removable) {
        this.IconAction($r('sys.symbol.trash'), $r('app.string.action_delete'), this.controlsEnabled,
          (): void => this.onDelete())
      }
    }.padding({ right: this.removable ? 8 : 0 }).width('100%')
      .backgroundColor(this.style.palette.cardBackground).borderRadius(24)
  }
}

@ComponentV2
export struct CustomProfileEditor {
  @Local private style: AppearanceState = appAppearance;
  @Param @Require store: ProfileStore;
  @Param @Require draft: CustomProfileDraft;
  @Event onClose: () => void = (): void => {};
  @Local private panel: CustomPanel = 'overview';
  @Local private view: CustomProfileView | undefined = undefined;
  @Local private ready: boolean = false;
  @Local private loadedError: boolean = false;
  @Local private groupName: string = '';
  @Local private groupType: string = 'select';
  @Local private members: string = '';
  @Local private providers: string = '';
  @Local private groupOptions: string = '';
  @Local private ruleType: string = 'MATCH';
  @Local private rulePayload: string = '';
  @Local private ruleExit: string = 'DIRECT';
  @Local private ruleParams: string = '';
  @Local private editIndex: number = -1;
  @Local private sourceText: string = '';
  @Local private urlText: string = '';
  @Local private yamlKey: string = '';
  @Local private editTitle: ResourceStr = '';
  @Local private choiceOpen: boolean = false;
  @Local private choices: CustomChoice[] = [];
  @Local private choiceTitle: ResourceStr = '';
  private yamlReturn: CustomPanel = 'overview';
  private choiceKind: CustomPicker = 'members';
  private choiceIndex: number = -1;
  private clickedChoice: CustomChoice | undefined = undefined;
  private library: LocalProxy[] = [];
  private active: boolean = false;
  private initialSource: string = CUSTOM_EMPTY_YAML;
  private yamlController: YamlCodeEditorController = new YamlCodeEditorController();
  private rows: ListSource<CustomEditorRow> = new ListSource<CustomEditorRow>();

  aboutToAppear(): void {
    this.active = true;
    this.load();
  }

  aboutToDisappear(): void { this.active = false; }

  private async load(): Promise<void> {
    this.draft.busy = true;
    this.loadedError = false;
    try {
      const source = this.draft.id === '' ? CUSTOM_EMPTY_YAML : await this.store.source(this.draft.id);
      if (!this.active) { return; }
      this.initialSource = source;
      try { this.publish(await inspectCustomProfile(source)); }
      catch (error) {
        if (!this.active) { return; }
        this.sourceText = source;
        this.yamlController.setFallback(source);
        this.yamlKey = '';
        this.editTitle = $r('app.string.custom_source');
        this.panel = 'text';
        this.toast(customFailure(error as Object));
      }
      this.ready = true;
    } catch (error) {
      this.loadedError = true;
      this.toast(customFailure(error as Object));
    } finally { this.draft.busy = false; }
  }

  private toast(message: ResourceStr): void {
    if (this.active) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }

  private publish(next: CustomProfileView): void {
    if (!this.active) { return; }
    this.view = next;
    this.draft.changed = next.source !== this.initialSource;
    this.refreshRows();
  }

  private go(panel: CustomPanel): void {
    this.draft.editing = false;
    this.panel = panel;
    this.refreshRows();
  }

  private refreshRows(): void {
    const view = this.view;
    const rows: CustomEditorRow[] = [];
    if (view !== undefined) {
      if (this.panel === 'groups') {
        view.groups.forEach((group: CustomGroup, index: number): void => {
          rows.push({ key: 'g:' + index + ':' + group.name, index: index, label: group.name || '—',
            detail: group.type + ' · ' + String(group.members.length + group.providers.length) });
        });
      } else if (this.panel === 'rules') {
        view.rules.forEach((rule: string, index: number): void => {
          rows.push({ key: 'r:' + index + ':' + rule, index: index, label: rule, detail: '' });
        });
      } else if (this.panel === 'nodes') {
        view.nodes.forEach((node: CustomNode, index: number): void => {
          rows.push({ key: 'n:' + index + ':' + node.name, index: index, label: node.name,
            detail: node.dialer === '' ? node.type : node.type + ' → ' + node.dialer });
        });
      } else if (this.panel === 'issues') {
        view.issues.forEach((problem: CustomIssue, index: number): void => {
          rows.push({ key: 'i:' + index, index: index, label: customIssueLabel(problem),
            detail: problem.blocking ? $r('app.string.custom_error') : $r('app.string.custom_warning') });
        });
      }
    }
    this.rows.replace(rows);
  }

  private async mutate(mutation: CustomProfileMutation, destination: CustomPanel): Promise<void> {
    const source = this.view?.source;
    if (source === undefined || this.draft.busy) { return; }
    this.draft.busy = true;
    try {
      this.publish(await inspectCustomProfile(source, mutation));
      if (this.active) { this.go(destination); }
    } catch (error) { this.toast(customFailure(error as Object)); }
    finally { this.draft.busy = false; }
  }

  private openGroup(index: number): void {
    const group = this.view?.groups[index];
    this.editIndex = index;
    this.groupName = group?.name ?? '';
    this.groupType = group?.type ?? 'select';
    this.members = group?.members.join('\n') ?? '';
    this.providers = group?.providers.join('\n') ?? '';
    this.groupOptions = group?.options ?? '';
    this.go('group');
  }

  private saveGroup(): void {
    const group: CustomGroup = { name: this.groupName, type: this.groupType, members: toNames(this.members),
      providers: toNames(this.providers), options: this.groupOptions };
    this.mutate({ kind: 'group', index: this.editIndex, group: group }, 'groups');
  }

  private openRule(index: number): void {
    this.editIndex = index;
    const parts = customRuleParts(this.view?.rules[index] ?? 'MATCH,DIRECT');
    this.ruleType = parts[0].toUpperCase();
    this.rulePayload = this.ruleType === 'MATCH' ? '' : parts[1] ?? '';
    this.ruleExit = parts[this.ruleType === 'MATCH' ? 1 : 2] ?? '';
    this.ruleParams = this.ruleType === 'MATCH' ? '' : parts.slice(3).join(',');
    this.go('rule');
  }

  private setRuleType(type: string): void {
    if (type === this.ruleType) { return; }
    if (this.ruleType === 'RULE-SET' || type === 'RULE-SET') { this.rulePayload = ''; }
    this.ruleType = type;
    this.draft.editing = true;
  }

  private async showYaml(key: string, label: ResourceStr, returns: CustomPanel = 'overview'): Promise<void> {
    if (this.draft.busy) { return; }
    const source = this.view?.source;
    if (source === undefined) { return; }
    this.draft.busy = true;
    try {
      const text = key === '' ? source : await readCustomSection(source, key);
      if (!this.active) { return; }
      this.sourceText = text;
      this.yamlController.setFallback(text);
      this.yamlKey = key;
      this.editTitle = label;
      this.yamlReturn = returns;
      this.go('text');
    } catch (error) { this.toast(customFailure(error as Object)); }
    finally { this.draft.busy = false; }
  }

  private async useSource(source: string, destination: CustomPanel): Promise<void> {
    this.publish(await inspectCustomProfile(source));
    if (this.active) { this.go(destination); }
  }

  private async saveSource(): Promise<void> {
    let text = this.sourceText;
    try { text = await this.yamlController.readText(); } catch (_error) {}
    this.sourceText = text;
    if (this.yamlKey !== '') {
      await this.mutate({ kind: 'section', field: this.yamlKey, text: text }, this.yamlReturn);
      return;
    }
    this.draft.busy = true;
    try { await this.useSource(text, this.yamlReturn); }
    catch (error) { this.toast(customFailure(error as Object)); }
    finally { this.draft.busy = false; }
  }

  private async importSource(file: boolean): Promise<void> {
    if (this.draft.busy) { return; }
    this.draft.busy = true;
    try {
      const source = file ? await this.store.pickSource() :
        await this.store.downloadCustomSource(this.urlText, (): boolean => !this.active);
      if (source !== undefined && this.active) { await this.useSource(source, 'overview'); }
    } catch (error) { this.toast(customFailure(error as Object)); }
    finally { this.draft.busy = false; }
  }

  private async save(): Promise<void> {
    const view = this.view;
    if (view === undefined || this.draft.busy) { return; }
    const name = this.draft.name.trim();
    if (name === '') { this.toast(describeError('name_empty')); return; }
    if (view.issues.some((problem: CustomIssue): boolean => problem.blocking)) {
      this.go('issues');
      return;
    }
    this.draft.busy = true;
    try {
      const content = this.draft.changed || this.draft.id === '' ? await serializeCustomProfile(view.source) : undefined;
      const failure = this.draft.id === '' ?
        await this.store.createCustom(name, content ?? CUSTOM_EMPTY_YAML, view.issues.length === 0) :
        await this.store.edit(this.draft.id, { name: name, url: '', autoUpdate: false, content: content,
          baseName: this.draft.baseName, baseContentRevision: this.draft.revision });
      if (failure !== undefined) { this.toast(describeError(failure)); return; }
      this.draft.changed = false;
      this.draft.name = this.draft.baseName;
      if (this.active) {
        this.toast(view.issues.length === 0 ? $r('app.string.custom_saved') : $r('app.string.custom_saved_warning'));
        this.onClose();
      }
    } catch (error) { this.toast(customFailure(error as Object)); }
    finally { this.draft.busy = false; }
  }

  private confirm(message: ResourceStr, action: () => void): void {
    let accepted = false;
    this.getUIContext().showActionSheet({
      title: '', message: message, alignment: DialogAlignment.Bottom, systemMaterial: this.style.sheetMaterial(),
      sheets: [{ title: $r('app.string.custom_continue'), action: (): void => { accepted = true; } }],
      confirm: { value: $r('app.string.action_cancel'), defaultFocus: true, action: (): void => {} },
      onWillDismiss: (event: DismissDialogAction): void => event.dismiss(),
      onDidDisappear: (): void => { if (accepted && this.active) { action(); } }
    });
  }

  private closePanel(): void {
    if (this.panel === 'overview' || this.view === undefined) {
      confirmCustomDismiss(this.getUIContext(), this.draft, this.onClose);
      return;
    }
    const next: CustomPanel = this.panel === 'group' ? 'groups' :
      this.panel === 'rule' ? 'rules' : this.panel === 'text' ? this.yamlReturn : 'overview';
    if (this.draft.editing && this.panel !== 'import') {
      this.confirm($r('app.string.profile_unsaved_message'), (): void => this.go(next));
    } else { this.go(next); }
  }

  private confirmImport(file: boolean): void {
    if (this.view?.source !== CUSTOM_EMPTY_YAML) {
      this.confirm($r('app.string.custom_import_replace'), (): void => { this.importSource(file); });
    } else { this.importSource(file); }
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private destinations(): string[] {
    const names = CUSTOM_BUILTINS.concat(this.view?.nodes.map((node: CustomNode): string => node.name) ?? [],
      this.view?.groups.map((group: CustomGroup): string => group.name) ?? []);
    return Array.from(new Set<string>(names));
  }

  private async openChoices(kind: CustomPicker, index: number = -1): Promise<void> {
    if (this.draft.busy) { return; }
    this.draft.busy = true;
    try {
      const choices = await this.loadChoices(kind, index);
      if (!this.active) { return; }
      if (choices.length === 0) { this.toast($r('app.string.custom_no_choices')); return; }
      this.choiceKind = kind;
      this.choiceIndex = index;
      this.choices = choices;
      this.clickedChoice = undefined;
      this.choiceTitle = this.choiceLabel(kind);
      this.choiceOpen = true;
    } catch (error) { this.toast(customFailure(error as Object)); }
    finally { this.draft.busy = false; }
  }

  private choiceLabel(kind: CustomPicker): ResourceStr {
    switch (kind) {
      case 'node': return $r('app.string.custom_from_library');
      case 'filter': return $r('app.string.custom_filter_preset');
      case 'providers': return $r('app.string.custom_choose_provider');
      case 'dialer': return $r('app.string.custom_dialer');
      case 'ruleProvider': return $r('app.string.custom_rule_providers');
      default: return $r('app.string.custom_choose_target');
    }
  }

  private async loadChoices(kind: CustomPicker, index: number): Promise<CustomChoice[]> {
    switch (kind) {
      case 'node': {
        this.library = (await readLocalProxies(this.context().filesDir)).proxies;
        const used = new Set<string>(this.destinations());
        return this.library.filter((node: LocalProxy): boolean => !used.has(proxyText(node.definition, ['name'])))
          .map((node: LocalProxy): CustomChoice => ({ key: node.id, label: proxyText(node.definition, ['name']),
            detail: proxyText(node.definition, ['type']) }));
      }
      case 'filter': {
        const presets = (await readProxyFilters(this.context().filesDir)).presets;
        return presets.map((preset: ProxyFilterPreset): CustomChoice => ({
          key: preset.id, label: preset.label, detail: preset.expression }));
      }
      case 'providers': {
        const used = new Set<string>(toNames(this.providers));
        return (this.view?.providers ?? []).filter((name: string): boolean => !used.has(name)).map(asChoice);
      }
      case 'ruleProvider': return (this.view?.ruleProviders ?? []).map(asChoice);
      case 'members': {
        const used = new Set<string>(toNames(this.members));
        used.add(this.view?.groups[this.editIndex]?.name ?? '');
        return this.destinations().filter((name: string): boolean => !used.has(name)).map(asChoice);
      }
      case 'dialer': {
        const name = this.view?.nodes[index]?.name;
        const options = this.destinations().filter((target: string): boolean => target !== name).map(asChoice);
        const noDialer = this.context().resourceManager.getStringSync($r('app.string.custom_no_dialer').id);
        options.unshift({ key: '', label: noDialer, detail: '' });
        return options;
      }
      default: return this.destinations().map(asChoice);
    }
  }

  private choose(): void {
    const choice = this.clickedChoice;
    this.clickedChoice = undefined;
    if (choice === undefined || !this.active) { return; }
    switch (this.choiceKind) {
      case 'members': this.members = toNames(this.members).concat(choice.key).join('\n'); break;
      case 'providers': this.providers = toNames(this.providers).concat(choice.key).join('\n'); break;
      case 'ruleTarget': this.ruleExit = choice.key; break;
      case 'ruleProvider': this.rulePayload = choice.key; break;
      case 'filter':
        this.addFilter(choice.detail);
        return;
      case 'dialer':
        this.mutate({ kind: 'dialer', index: this.choiceIndex, text: choice.key }, 'nodes');
        return;
      case 'node': {
        const node = this.library.find((item: LocalProxy): boolean => item.id === choice.key);
        if (node !== undefined) { this.mutate({ kind: 'node', definition: node.definition }, 'nodes'); }
        return;
      }
    }
    this.draft.editing = true;
  }

  private async addFilter(expression: string): Promise<void> {
    this.draft.busy = true;
    try {
      const options = await applyCustomGroupFilter(this.groupOptions, expression);
      if (this.active) { this.groupOptions = options; this.draft.editing = true; }
    } catch (error) { this.toast(customFailure(error as Object)); }
    finally { this.draft.busy = false; }
  }

  private title(): ResourceStr {
    switch (this.panel) {
      case 'overview': return $r('app.string.custom_profile');
      case 'groups': return $r('app.string.custom_groups');
      case 'group': return $r('app.string.custom_group');
      case 'rules': return $r('app.string.custom_rules');
      case 'rule': return $r('app.string.custom_rule');
      case 'nodes': return $r('app.string.custom_nodes');
      case 'import': return $r('app.string.custom_import');
      case 'text': return this.editTitle;
      default: return $r('app.string.custom_issues');
    }
  }

  private canSave(): boolean {
    if (!this.ready) { return false; }
    switch (this.panel) {
      case 'overview': return this.view !== undefined && this.draft.dirty();
      case 'group': return this.groupName.trim() !== '';
      case 'rule': return this.ruleExit.trim() !== '' && (this.ruleType === 'MATCH' || this.rulePayload.trim() !== '');
      case 'text': return this.draft.editing;
      default: return false;
    }
  }

  private savePanel(): void {
    switch (this.panel) {
      case 'overview': this.save(); break;
      case 'group': this.saveGroup(); break;
      case 'rule': {
        const parts = this.ruleType === 'MATCH' ? ['MATCH', this.ruleExit.trim()] :
          [this.ruleType, this.rulePayload.trim(), this.ruleExit.trim()];
        if (this.ruleType !== 'MATCH' && !customRuleAllowsComma(this.ruleType) && this.ruleParams.trim() !== '') {
          parts.push(this.ruleParams.trim());
        }
        this.mutate({ kind: 'rule', index: this.editIndex, text: parts.join(',') }, 'rules');
        break;
      }
      case 'text': this.saveSource(); break;
    }
  }

  private order(index: number, offset?: number): void {
    const key = this.panel === 'groups' ? 'proxy-groups' : this.panel === 'rules' ? 'rules' : 'proxies';
    const destination = this.panel;
    const change: CustomProfileMutation = { kind: 'order', index: index, field: key, offset: offset };
    if (offset === undefined && destination !== 'rules') {
      this.confirm($r('app.string.custom_remove_target'), (): void => { this.mutate(change, destination); });
    } else { this.mutate(change, destination); }
  }

  private openRow(index: number): void {
    if (this.draft.busy) { return; }
    switch (this.panel) {
      case 'groups': this.openGroup(index); break;
      case 'rules': this.openRule(index); break;
      case 'nodes': this.openChoices('dialer', index); break;
    }
  }

  @Builder
  Action(label: ResourceStr, action: () => void) {
    Button(label, { type: ButtonType.Normal, buttonStyle: ButtonStyleMode.NORMAL })
      .fontFamily(this.style.fontFamily).fontSize(15).borderRadius(22).constraintSize({ minHeight: 44 })
      .enabled(!this.draft.busy).onClick(action)
  }

  @Builder
  Label(label: ResourceStr) {
    Text(label).fontFamily(this.style.fontFamily).fontSize(14)
      .fontColor($r('sys.color.font_secondary')).width('100%')
  }

  @Builder
  Overview() {
    Scroll() {
      Column({ space: 8 }) {
        this.Label($r('app.string.field_name'))
        TextInput({ text: this.draft.name, placeholder: $r('app.string.custom_unnamed') })
          .fontFamily(this.style.fontFamily).maxLength(64)
          .onChange((text: string): void => { this.draft.name = text; })
        CustomProfileRow({ entry: { key: 'groups', index: -1, label: $r('app.string.custom_groups'),
          detail: String(this.view?.groups.length ?? 0) }, onOpen: (): void => this.go('groups') })
        CustomProfileRow({ entry: { key: 'rules', index: -1, label: $r('app.string.custom_rules'),
          detail: String(this.view?.rules.length ?? 0) }, onOpen: (): void => this.go('rules') })
        CustomProfileRow({ entry: { key: 'nodes', index: -1, label: $r('app.string.custom_nodes'),
          detail: String(this.view?.nodes.length ?? 0) }, onOpen: (): void => this.go('nodes') })
        if ((this.view?.issues.length ?? 0) > 0) {
          CustomProfileRow({ entry: { key: 'issues', index: -1, label: $r('app.string.custom_issues'),
            detail: String(this.view?.issues.length ?? 0) }, onOpen: (): void => this.go('issues') })
        }
        CustomProfileRow({ entry: { key: 'providers', index: -1, label: $r('app.string.custom_proxy_providers'),
          detail: String(this.view?.providers.length ?? 0) },
          onOpen: (): void => { this.showYaml('proxy-providers', $r('app.string.custom_proxy_providers')); } })
        CustomProfileRow({ entry: { key: 'rule-providers', index: -1, label: $r('app.string.custom_rule_providers'),
          detail: String(this.view?.ruleProviders.length ?? 0) },
          onOpen: (): void => { this.showYaml('rule-providers', $r('app.string.custom_rule_providers')); } })
        Row({ space: 8 }) {
          this.Action('DNS', (): void => { this.showYaml('dns', 'DNS'); })
          this.Action('NTP', (): void => { this.showYaml('ntp', 'NTP'); })
          this.Action($r('app.string.custom_sniffer'), (): void => {
            this.showYaml('sniffer', $r('app.string.custom_sniffer'));
          })
        }.width('100%')
        Row({ space: 8 }) {
          this.Action($r('app.string.custom_import'), (): void => { this.urlText = ''; this.go('import'); })
          this.Action($r('app.string.custom_source'), (): void => {
            this.showYaml('', $r('app.string.custom_source'));
          })
        }.width('100%')
      }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder
  RecordList() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        if (this.panel === 'groups') {
          this.Action($r('app.string.custom_add_group'), (): void => this.openGroup(-1))
        } else if (this.panel === 'rules') {
          this.Action($r('app.string.custom_add_rule'), (): void => this.openRule(-1))
          this.Action('YAML', (): void => { this.showYaml('rules', $r('app.string.custom_rules'), 'rules'); })
          this.Action($r('app.string.custom_sub_rules'), (): void => {
            this.showYaml('sub-rules', $r('app.string.custom_sub_rules'), 'rules');
          })
        } else if (this.panel === 'nodes') {
          this.Action($r('app.string.custom_from_library'), (): void => { this.openChoices('node'); })
          this.Action('YAML', (): void => { this.showYaml('proxies', $r('app.string.custom_nodes'), 'nodes'); })
        }
      }.width('100%')
      if (this.panel === 'nodes') { this.Label($r('app.string.custom_dialer_hint')) }
      if (this.panel !== 'issues' && this.rows.totalCount() === 0) {
        this.Label($r('app.string.custom_empty'))
      }
      List({ space: 8 }) {
        LazyForEach(this.rows, (entry: CustomEditorRow) => {
          ListItem() {
            CustomProfileRow({ entry: entry, ordered: this.panel === 'rules' || this.panel === 'groups',
              removable: this.panel !== 'issues', last: entry.index === this.rows.totalCount() - 1,
              controlsEnabled: !this.draft.busy, onOpen: (): void => this.openRow(entry.index),
              onMove: (offset: number): void => this.order(entry.index, offset),
              onDelete: (): void => this.order(entry.index) })
          }
        }, (entry: CustomEditorRow): string => entry.key)
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }.layoutWeight(1).width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
  }

  @Builder
  GroupForm() {
    Scroll() {
      Column({ space: 8 }) {
        this.Label($r('app.string.field_name'))
        TextInput({ text: this.groupName }).fontFamily(this.style.fontFamily).maxLength(64)
          .onChange((text: string): void => { this.groupName = text; this.draft.editing = true; })
        this.Label($r('app.string.custom_type'))
        Select(GROUP_OPTIONS).value(this.groupType).selected(CUSTOM_GROUP_TYPES.indexOf(this.groupType))
          .onSelect((_index: number, type: string): void => {
            this.groupType = type;
            this.draft.editing = true;
          })
        Row({ space: 8 }) {
          this.Action($r('app.string.custom_choose_member'), (): void => { this.openChoices('members'); })
          this.Action($r('app.string.custom_choose_provider'), (): void => { this.openChoices('providers'); })
        }.width('100%')
        this.Label($r('app.string.custom_members'))
        TextArea({ text: this.members }).fontFamily(this.style.fontFamily).height(104)
          .onChange((text: string): void => { this.members = text; this.draft.editing = true; })
        this.Label($r('app.string.custom_group_providers'))
        TextArea({ text: this.providers }).fontFamily(this.style.fontFamily).height(88)
          .onChange((text: string): void => { this.providers = text; this.draft.editing = true; })
        Row({ space: 8 }) {
          this.Action($r('app.string.custom_filter_preset'), (): void => { this.openChoices('filter'); })
        }.width('100%')
        this.Label($r('app.string.custom_group_options'))
        TextArea({ text: this.groupOptions }).fontFamily('monospace').height(160)
          .onChange((text: string): void => { this.groupOptions = text; this.draft.editing = true; })
      }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder
  RuleForm() {
    Scroll() {
      Column({ space: 8 }) {
        this.Label($r('app.string.custom_type'))
        Select(RULE_OPTIONS).value(this.ruleType).selected(CUSTOM_RULE_TYPES.indexOf(this.ruleType))
          .onSelect((_index: number, type: string): void => this.setRuleType(type))
        if (this.ruleType !== 'MATCH') {
          this.Label($r('app.string.custom_rule_payload'))
          TextInput({ text: this.rulePayload }).fontFamily(this.style.fontFamily)
            .onChange((text: string): void => { this.rulePayload = text; this.draft.editing = true; })
          if (this.ruleType === 'RULE-SET') {
            this.Action($r('app.string.custom_rule_providers'), (): void => { this.openChoices('ruleProvider'); })
          }
        }
        this.Label($r('app.string.custom_rule_target'))
        TextInput({ text: this.ruleExit }).fontFamily(this.style.fontFamily)
          .onChange((text: string): void => { this.ruleExit = text; this.draft.editing = true; })
        if (this.ruleType !== 'SUB-RULE') {
          this.Action($r('app.string.custom_choose_target'), (): void => { this.openChoices('ruleTarget'); })
        }
        if (this.ruleType !== 'MATCH' && !customRuleAllowsComma(this.ruleType)) {
          this.Label($r('app.string.custom_rule_options'))
          TextInput({ text: this.ruleParams, placeholder: 'no-resolve,src' }).fontFamily(this.style.fontFamily)
            .onChange((text: string): void => { this.ruleParams = text; this.draft.editing = true; })
        }
      }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }

  @Builder
  ImportForm() {
    Column({ space: 12 }) {
      TextInput({ text: this.urlText, placeholder: $r('app.string.subscription_link') })
        .fontFamily(this.style.fontFamily).maxLength(2048).enabled(!this.draft.busy)
        .onChange((text: string): void => { this.urlText = text; })
      Row({ space: 8 }) {
        if (this.urlText.trim() !== '') {
          this.Action($r('app.string.custom_from_link'), (): void => this.confirmImport(false))
        }
        this.Action($r('app.string.profile_import_file'), (): void => this.confirmImport(true))
      }.width('100%')
    }.layoutWeight(1).width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8 })
  }

  @Builder
  ChoicesSheet() {
    CustomProfileChoice({ options: this.choices, onChoose: (choice: CustomChoice): void => {
      this.clickedChoice = choice;
      this.choiceOpen = false;
    } })
  }

  build() {
    Column() {
      ProfileSheetHeader({ titleText: this.title(), canSave: this.canSave(), saving: this.draft.busy,
        onClose: (): void => this.closePanel(), onSave: (): void => this.savePanel() })
      if (this.loadedError) {
        this.Action($r('app.string.custom_retry'), (): void => { this.load(); })
      } else if (this.ready) {
        if (this.panel === 'overview') {
          this.Overview()
        } else if (this.panel === 'group') {
          this.GroupForm()
        } else if (this.panel === 'rule') {
          this.RuleForm()
        } else if (this.panel === 'text') {
          YamlCodeEditor({
            initialText: this.sourceText,
            readOnly: false,
            editorEnabled: !this.draft.busy,
            foreground: true,
            controller: this.yamlController,
            onDirtyChange: (dirty: boolean): void => { if (dirty) { this.draft.editing = true; } }
          })
        } else if (this.panel === 'import') {
          this.ImportForm()
        } else {
          this.RecordList()
        }
      }
    }.width('100%').height('100%')
      .bindSheet($$this.choiceOpen, this.ChoicesSheet(), { title: { title: this.choiceTitle },
        height: SheetSize.LARGE, systemMaterial: this.style.sheetMaterial(), showClose: true,
        onDisappear: (): void => this.choose() })
  }
}
