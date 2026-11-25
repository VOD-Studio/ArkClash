import { common } from '@kit.AbilityKit';
import { url } from '@kit.ArkTS';
import {
  changeRuleSets, newRuleSet, readRuleSetPreview, readRuleSets, RULE_SET_EDITOR_LIMIT, RuleSetCatalog, RuleSetItem
} from '../../client/RuleSets';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ScrollDestination } from '../../components/ScrollDestination';
import { EmptyState } from '../../components/EmptyState';
import { formatUpdatedAgo } from '../../components/Format';
import { KeyedListSource } from '../../components/KeyedListSource';
import { HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { pickDocumentFile, documentFileName } from '../../client/DocumentPicker';

type RuleSetSheet = 'new' | 'remote' | 'file' | 'edit' | 'options' | 'preview' | 'delete';

const RULE_SET_BEHAVIORS: string[] = ['auto', 'domain', 'ipcidr', 'classical'];
const RULE_SET_FORMATS: string[] = ['auto', 'yaml', 'text', 'mrs'];
const RULE_SET_BEHAVIOR_OPTIONS: SelectOption[] = [
  { value: $r('app.string.rule_set_auto') }, { value: 'domain' }, { value: 'ipcidr' }, { value: 'classical' }
];
const RULE_SET_FORMAT_OPTIONS: SelectOption[] = [
  { value: $r('app.string.rule_set_auto') }, { value: 'YAML' }, { value: 'Text' }, { value: 'MRS' }
];

class RuleSetRowItem {
  readonly key: string;
  readonly item: RuleSetItem;
  readonly updated: ResourceStr;

  constructor(item: RuleSetItem) {
    this.item = item;
    this.key = item.id;
    this.updated = formatUpdatedAgo(item.updatedAt, Date.now());
  }
}

@ComponentV2
export struct RuleSetsPage {
  @Param foreground: boolean = true;
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private busy: boolean = false;
  @Local private sheetShown: boolean = false;
  @Local private sheetMode: RuleSetSheet = 'new';
  @Local private selected: RuleSetItem = newRuleSet();
  @Local private nameText: string = '';
  @Local private urlText: string = '';
  @Local private sourceText: string = '';
  @Local private behavior: string = 'auto';
  @Local private format: string = 'auto';
  @Local private issue: ResourceStr = '';
  @Local private truncated: boolean = false;
  @Local private dirty: boolean = false;
  @Local private confirmDiscard: boolean = false;
  @Local private count: number = 0;
  @Local private sorting: boolean = false;
  @Local private first: string = '';
  @Local private last: string = '';

  private catalog: RuleSetCatalog = { revision: 'default', items: [] };
  private shown: boolean = false;
  private rows: KeyedListSource<RuleSetRowItem> = new KeyedListSource<RuleSetRowItem>();
  private fileUri: string = '';

  @Computed
  get behaviorIndex(): number {
    return Math.max(0, RULE_SET_BEHAVIORS.indexOf(this.behavior));
  }

  @Computed
  get formatIndex(): number {
    return Math.max(0, RULE_SET_FORMATS.indexOf(this.format));
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private publish(catalog: RuleSetCatalog): void {
    this.catalog = catalog;
    const items = catalog.items;
    this.count = items.length;
    this.first = items[0]?.id ?? '';
    this.last = items[items.length - 1]?.id ?? '';
    this.rows.replace(items.map((item: RuleSetItem): RuleSetRowItem => new RuleSetRowItem(item)));
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      this.publish(await readRuleSets(this.context().filesDir));
      this.failed = false;
    } catch (_error) {
      this.failed = true;
    } finally {
      this.loading = false;
    }
  }

  private toast(message: ResourceStr): void {
    if (this.shown && this.foreground) {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private errorText(error: Error): Resource {
    switch (error.message) {
      case 'rule_set_input': return $r('app.string.rule_set_invalid');
      case 'rule_set_content': return $r('app.string.rule_set_bad_content');
      case 'rule_set_download': return $r('app.string.rule_set_download_error');
      case 'rule_set_in_use': return $r('app.string.rule_set_in_use');
      case 'rule_set_core': return $r('app.string.added_rules_unavailable');
      case 'profile_settings_conflict': return $r('app.string.added_rules_conflict');
      default: return $r('app.string.rule_set_failed');
    }
  }

  private open(mode: RuleSetSheet, item: RuleSetItem = newRuleSet(), source: string = '',
    uri: string = '', truncated: boolean = false): void {
    this.sheetMode = mode;
    this.selected = item;
    this.nameText = item.name;
    this.urlText = item.url;
    this.behavior = item.behavior;
    this.format = item.format;
    this.sourceText = source;
    this.fileUri = uri;
    this.truncated = truncated;
    this.dirty = false;
    this.confirmDiscard = false;
    this.issue = '';
    this.sheetShown = true;
  }

  private async openItem(item: RuleSetItem): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      const page = await readRuleSetPreview(this.context().filesDir, item);
      if (this.shown) {
        const editable = item.url === '' && item.format !== 'mrs' && !page.truncated;
        this.open(editable ? 'edit' : 'preview', item, page.text, '', page.truncated);
      }
    } catch (error) {
      this.toast(this.errorText(error as Error));
    } finally {
      this.busy = false;
    }
  }

  private markChanged(): void {
    this.dirty = true;
    this.issue = '';
  }

  private closeSheet(dismiss: () => void): void {
    if (this.busy) { return; }
    if (this.dirty && this.sheetMode !== 'preview') {
      this.confirmDiscard = !this.confirmDiscard;
      return;
    }
    dismiss();
  }

  private uniqueName(name: string): string {
    const base = name.trim().slice(0, 70) || 'Rule Set';
    let candidate = base;
    let suffix = 2;
    while (this.catalog.items.some((item: RuleSetItem): boolean => item.name === candidate)) {
      candidate = `${base} (${suffix++})`;
    }
    return candidate;
  }

  private async importFile(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      const uri = await pickDocumentFile(this.context());
      if (uri !== undefined && this.shown) {
        const name = this.uniqueName(documentFileName(uri).replace(/\.[^.]+$/, ''));
        this.open('file', newRuleSet(name), '', uri);
      }
    } catch (error) {
      this.toast(this.errorText(error as Error));
    } finally {
      this.busy = false;
    }
  }

  private itemForSave(): RuleSetItem {
    const item = this.selected;
    return { id: item.id, name: this.nameText.trim(), url: this.urlText.trim(), behavior: this.behavior,
      format: this.format, content: item.content, count: item.count, updatedAt: item.updatedAt };
  }

  private urlName(source: string): string {
    const target = url.URL.parseURL(source);
    return this.uniqueName(documentFileName(target.pathname).replace(/\.[^.]+$/, '') || target.hostname);
  }

  private async importUrls(): Promise<void> {
    const urls = Array.from(new Set<string>(this.urlText.trim().split(/\s+/).filter((line: string): boolean => line !== '')));
    if (urls.length === 0 || urls.length > 20) {
      throw new Error('rule_set_input');
    }
    const failed: string[] = [];
    for (let index = 0; index < urls.length; index++) {
      const source = urls[index];
      try {
        const generated = this.urlName(source);
        const name = urls.length === 1 && this.nameText.trim() !== '' ? this.nameText.trim() : generated;
        const item = newRuleSet(name, source);
        item.behavior = this.behavior;
        item.format = this.format;
        this.publish(await changeRuleSets(this.context(), this.catalog, 'save', item));
      } catch (error) {
        if (urls.length === 1 || (error as Error).message === 'profile_settings_conflict') { throw error as Error; }
        failed.push(String(index + 1));
      }
    }
    if (failed.length > 0) {
      this.urlText = failed.map((index: string): string => urls[Number(index) - 1]).join('\n');
      this.issue = $r('app.string.rule_set_batch_failed', failed.join(', '));
      return;
    }
    this.sheetShown = false;
    this.toast($r('app.string.rule_set_saved'));
  }

  private async save(): Promise<void> {
    if (this.busy) { return; }
    if (!this.dirty && (this.sheetMode === 'edit' || this.sheetMode === 'options')) {
      this.sheetShown = false;
      return;
    }
    this.busy = true;
    this.issue = '';
    try {
      if (this.sheetMode === 'remote') {
        await this.importUrls();
        return;
      }
      const item = this.itemForSave();
      const editing = this.sheetMode === 'new' || this.sheetMode === 'edit';
      const text = editing ? this.sourceText : undefined;
      if (item.name === '' || (this.selected.url !== '' && item.url === '') || (editing && (this.sourceText.trim() === '' ||
        this.sourceText.length > RULE_SET_EDITOR_LIMIT))) {
        throw new Error('rule_set_invalid_form');
      }
      this.publish(await changeRuleSets(this.context(), this.catalog, 'save', item, text,
        this.fileUri === '' ? undefined : this.fileUri));
      this.sheetShown = false;
      this.toast($r('app.string.rule_set_saved'));
    } catch (error) {
      const message = (error as Error).message;
      if (message === 'profile_settings_conflict') { await this.load(); }
      this.issue = message === 'rule_set_invalid_form' ?
        $r('app.string.rule_set_invalid') : this.errorText(error as Error);
    } finally {
      this.busy = false;
    }
  }

  private async run(action: string, item?: RuleSetItem, order?: string[]): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      this.publish(await changeRuleSets(this.context(), this.catalog, action, item, undefined, undefined, order));
      this.sheetShown = false;
      this.toast(action === 'sync' ? $r('app.string.rule_set_synced') : $r('app.string.rule_set_saved'));
    } catch (error) {
      if ((error as Error).message === 'profile_settings_conflict') { await this.load(); }
      this.publish(this.catalog);
      const message = this.errorText(error as Error);
      if (this.sheetShown) { this.issue = message; } else { this.toast(message); }
    } finally {
      this.busy = false;
    }
  }

  private move(from: number, to: number): void {
    if (from === to || from < 0 || to < 0 || from >= this.count || to >= this.count) { return; }
    const ids = this.catalog.items.map((item: RuleSetItem): string => item.id);
    const moved = ids.splice(from, 1)[0];
    ids.splice(to, 0, moved);
    this.run('reorder', undefined, ids);
  }

  private sheetTitle(): ResourceStr {
    switch (this.sheetMode) {
      case 'new': return $r('app.string.rule_set_new');
      case 'file': return $r('app.string.action_import_file');
      case 'remote': return $r('app.string.script_import_url');
      case 'options': return $r('app.string.network_options');
      case 'delete': return $r('app.string.action_delete');
      default: return this.selected.name;
    }
  }

  @Builder
  AddMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.rule_set_new') })
        .onClick((): void => this.open('new'))
      MenuItem({ content: $r('app.string.script_import_url') }).onClick((): void => { this.open('remote'); })
      MenuItem({ content: $r('app.string.action_import_file') }).onClick((): void => { this.importFile(); })
    }
  }

  @Builder
  RowMenu(item: RuleSetItem) {
    Menu() {
      if (item.url !== '') {
        MenuItem({ content: $r('app.string.rule_set_sync') }).onClick((): void => { this.run('sync', item); })
      }
      MenuItem({ content: $r('app.string.network_options') }).onClick((): void => this.open('options', item))
      MenuItem({ content: $r('app.string.action_delete') }).onClick((): void => this.open('delete', item))
    }
  }

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: $r('app.string.rule_set_title') })
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      if (this.busy) {
        LoadingProgress().width(24).height(24).color(this.appStyle.palette.brand)
      }
      if (this.count > 1) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(this.sorting ? $r('sys.symbol.checkmark') : $r('sys.symbol.sort'))
            .fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
        }
        .attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
        .accessibilityText($r('app.string.profile_sort'))
        .enabled(!this.busy)
        .onClick((): void => { this.sorting = !this.sorting; })
      }
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($r('app.string.action_add'))
      .enabled(!this.busy && !this.loading && !this.failed && !this.sorting)
      .bindMenu(this.AddMenu)
    }
    .height('100%').alignItems(VerticalAlign.Center).padding({ right: PAGE_GUTTER })
  }

  @Builder
  SetRow(row: RuleSetRowItem) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(row.item.name).fontFamily(this.appStyle.fontFamily).fontSize(16).fontWeight(FontWeight.Medium).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '68%' })
          Text(row.item.behavior).fontSize(11).fontColor(this.appStyle.palette.brand)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(this.appStyle.palette.selectionTonal).borderRadius(6)
        }.width('100%')
        Text(row.item.url === '' ? $r('app.string.rule_set_local') : $r('app.string.rule_set_remote'))
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start).padding({ top: 10, bottom: 10 }).onClick((): void => {
        if (!this.sorting) { this.openItem(row.item); }
      })
      if (this.sorting) {
        SymbolGlyph($r('sys.symbol.line_3_horizontal')).fontSize(20).fontColor([$r('sys.color.font_secondary')])
          .accessibilityText($r('app.string.profile_sort'))
      } else {
        Text(row.updated).fontSize(12).fontColor($r('sys.color.font_secondary'))
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(21).fontColor([$r('sys.color.font_secondary')])
        }
        .width(40).height(40).accessibilityText($r('app.string.action_more'))
        .bindMenu((): void => this.RowMenu(row.item))
      }
    }
    .width('100%').constraintSize({ minHeight: 64 }).padding({ left: 16, right: 8 })
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius({ topLeft: row.key === this.first ? 22 : 0, topRight: row.key === this.first ? 22 : 0,
      bottomLeft: row.key === this.last ? 22 : 0, bottomRight: row.key === this.last ? 22 : 0 })
  }

  @Builder
  FormFields() {
    if (this.sheetMode !== 'preview' && this.sheetMode !== 'delete') {
      TextInput({ text: this.nameText, placeholder: $r('app.string.rule_set_name') })
        .maxLength(80).height(48).onChange((input: string): void => { this.nameText = input; this.markChanged(); })
      if (this.sheetMode === 'remote') {
        TextArea({ text: this.urlText, placeholder: $r('app.string.rule_set_urls') })
          .height(128).maxLength(42000).onChange((input: string): void => { this.urlText = input; this.markChanged(); })
      } else if (this.sheetMode === 'options' && this.selected.url !== '') {
        TextInput({ text: this.urlText, placeholder: $r('app.string.script_url') })
          .type(InputType.URL).maxLength(2048).height(48)
          .onChange((input: string): void => { this.urlText = input; this.markChanged(); })
      }
      Row({ space: 12 }) {
        Text($r('app.string.rule_set_behavior')).layoutWeight(1)
        Select(RULE_SET_BEHAVIOR_OPTIONS).selected(this.behaviorIndex)
          .value(RULE_SET_BEHAVIOR_OPTIONS[this.behaviorIndex].value)
          .onSelect((index: number): void => {
            this.behavior = RULE_SET_BEHAVIORS[index] ?? 'auto';
            this.markChanged();
          })
      }.width('100%')
      Row({ space: 12 }) {
        Text($r('app.string.rule_set_format')).layoutWeight(1)
        Select(RULE_SET_FORMAT_OPTIONS).selected(this.formatIndex)
          .value(RULE_SET_FORMAT_OPTIONS[this.formatIndex].value)
          .onSelect((index: number): void => {
            this.format = RULE_SET_FORMATS[index] ?? 'auto';
            this.markChanged();
          })
      }.width('100%')
    }
    if (this.sheetMode === 'edit' || this.sheetMode === 'new') {
      TextArea({ text: this.sourceText, placeholder: $r('app.string.rule_set_content_hint') })
        .height(260).maxLength(RULE_SET_EDITOR_LIMIT).fontFamily('monospace').fontSize(13)
        .onChange((input: string): void => { this.sourceText = input; this.markChanged(); })
    } else if (this.sheetMode === 'preview') {
      if (this.truncated) {
        Text($r('app.string.rule_set_preview_partial')).fontSize(13).fontColor($r('sys.color.font_secondary'))
      }
      Text(this.sourceText).fontFamily('monospace').fontSize(13)
        .copyOption(CopyOptions.LocalDevice).width('100%')
    } else if (this.sheetMode === 'delete') {
      Text($r('app.string.rule_set_delete', this.selected.name)).fontColor($r('sys.color.font_secondary'))
    }
  }

  @Builder
  SheetBody() {
    Scroll() {
      Column({ space: 12 }) {
        this.FormFields()
        if (this.issue !== '') {
          Text(this.issue).fontSize(14).fontColor($r('app.color.status_error'))
        }
        if (this.confirmDiscard) {
          Text($r('app.string.added_rules_unsaved')).fontSize(14).fontColor($r('sys.color.font_secondary'))
          Row({ space: 12 }) {
            Button($r('app.string.added_rules_resume')).buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1)
              .onClick((): void => { this.confirmDiscard = false; })
            Button($r('app.string.added_rules_discard')).role(ButtonRole.ERROR).layoutWeight(1)
              .onClick((): void => { this.sheetShown = false; })
          }.width('100%')
        } else if (this.sheetMode !== 'preview') {
          Row({ space: 12 }) {
            Button($r('app.string.action_cancel')).buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1)
              .onClick((): void => this.closeSheet((): void => { this.sheetShown = false; }))
            if (this.sheetMode === 'delete') {
              Button($r('app.string.action_delete')).role(ButtonRole.ERROR).layoutWeight(1)
                .onClick((): void => { this.run('delete', this.selected); })
            } else {
              Button($r('app.string.action_save')).layoutWeight(1).onClick((): void => { this.save(); })
            }
          }.width('100%')
        }
      }
      .width('100%').alignItems(HorizontalAlign.Start).enabled(!this.busy)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
    }
    .width('100%')
    .height(this.sheetMode === 'delete' ? 'auto' : '100%')
    .align(Alignment.Top)
    .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
  }

  build() {
    ScrollDestination({
      heading: (): void => this.HeaderTitle(),
      actions: (): void => this.HeaderMenus(),
      pageShown: (): void => { this.shown = true; if (!this.busy) { this.load(); } },
      pageHidden: (): void => { this.shown = false; },
      handleBack: (): boolean => {
        if (this.sheetShown) {
          this.closeSheet((): void => { this.sheetShown = false; });
          return true;
        }
        if (this.sorting) {
          this.sorting = false;
          return true;
        }
        return false;
      }
    }) {
      Stack() {
        if (this.loading) {
          LoadingProgress().width(30).height(30)
        } else if (this.failed || this.count === 0) {
          EmptyState({
            icon: $r('sys.symbol.list_bullet'),
            title: this.failed ? $r('app.string.rule_set_failed') : $r('app.string.rule_set_empty'),
            actionLabel: this.failed ? $r('app.string.dns_override_retry') : '',
            onAction: (): void => { this.load(); }
          })
        } else {
          List({ space: 1 }) {
            LazyForEach(this.rows, (row: RuleSetRowItem) => {
              ListItem() { this.SetRow(row) }
            }, (row: RuleSetRowItem): string => row.key)
              .onMove(this.sorting && !this.busy ? (from: number, to: number): void => this.move(from, to) : undefined)
          }
          .width('100%').height('100%').enabled(!this.busy)
          .scrollBar(BarState.Off).cachedCount(2, true).contentStartOffset(12).contentEndOffset(24)
          .clipContent(ContentClipMode.SAFE_AREA)
          .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
        }
        Column().bindSheet($$this.sheetShown, this.SheetBody, {
          title: { title: this.sheetTitle() }, height: this.sheetMode === 'delete' ? SheetSize.FIT_CONTENT : SheetSize.LARGE,
          systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
          onWillDismiss: (action: DismissSheetAction): void => this.closeSheet((): void => action.dismiss())
        })
      }.width('100%').height('100%')
    }
  }
}
