import { common } from '@kit.AbilityKit';
import { checkProxyFilter } from '../../client/ProxyFilterValidation';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { EmptyState } from '../../components/EmptyState';
import { KeyedListSource } from '../../components/KeyedListSource';
import { HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import {
  commitProxyFilters, newProxyFilter, PROXY_FILTER_EXPRESSION_LIMIT, PROXY_FILTER_LABEL_LIMIT, proxyFilterProblem,
  ProxyFilterPreset, ProxyFilterSnapshot, readProxyFilters, searchProxyFilters
} from '../../shared/profiles/ProxyFilters';

class ProxyFilterRowItem {
  readonly key: string;
  readonly preset: ProxyFilterPreset;

  constructor(preset: ProxyFilterPreset) {
    this.key = preset.id;
    this.preset = preset;
  }
}

@ComponentV2
export struct ProxyFiltersPage {
  @Param @Require topInset: number;
  @Param foreground: boolean = true;
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private loading: boolean = true;
  @Local private loadFailed: boolean = false;
  @Local private saving: boolean = false;
  @Local private searchShown: boolean = false;
  @Local private query: string = '';
  @Local private managing: boolean = false;
  @Local private selectedIds: string[] = [];
  @Local private count: number = 0;
  @Local private visibleIds: string[] = [];
  @Local private firstId: string = '';
  @Local private lastId: string = '';
  @Local private sheetShown: boolean = false;
  @Local private deleting: boolean = false;
  @Local private discardRequested: boolean = false;
  @Local private editing: ProxyFilterPreset | undefined = undefined;
  @Local private labelDraft: string = '';
  @Local private expressionDraft: string = '';
  @Local private issue: ResourceStr = '';

  private snapshot: ProxyFilterSnapshot = { revision: '', presets: [] };
  private shown: boolean = false;
  private rows: KeyedListSource<ProxyFilterRowItem> = new KeyedListSource<ProxyFilterRowItem>();

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      this.publish(await readProxyFilters(this.context().filesDir));
      this.loadFailed = false;
    } catch (_error) {
      this.loadFailed = true;
    } finally {
      this.loading = false;
    }
  }

  private publish(snapshot: ProxyFilterSnapshot): void {
    this.snapshot = snapshot;
    this.count = snapshot.presets.length;
    this.refreshRows();
  }

  private refreshRows(): void {
    const visible = searchProxyFilters(this.snapshot.presets, this.query);
    this.visibleIds = visible.map((preset: ProxyFilterPreset): string => preset.id);
    this.firstId = this.visibleIds[0] ?? '';
    this.lastId = this.visibleIds[this.visibleIds.length - 1] ?? '';
    const available = new Set<string>(this.snapshot.presets.map((preset: ProxyFilterPreset): string => preset.id));
    this.selectedIds = this.selectedIds.filter((id: string): boolean => available.has(id));
    this.rows.replace(visible.map((preset: ProxyFilterPreset): ProxyFilterRowItem => new ProxyFilterRowItem(preset)));
  }

  private toast(message: ResourceStr): void {
    if (this.shown && this.foreground) {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private errorText(reason: string): Resource {
    switch (reason) {
      case 'proxy_filter_label': return $r('app.string.proxy_filter_label_invalid');
      case 'proxy_filter_duplicate': return $r('app.string.proxy_filter_duplicate');
      case 'proxy_filter_expression': return $r('app.string.proxy_filter_expression_invalid');
      case 'proxy_filter_core': return $r('app.string.added_rules_unavailable');
      case 'proxy_filter_conflict': return $r('app.string.added_rules_conflict');
      default: return $r('app.string.proxy_filter_error');
    }
  }

  private toggleSearch(): void {
    this.searchShown = !this.searchShown;
    if (!this.searchShown) {
      this.query = '';
      this.refreshRows();
    }
  }

  private openEditor(preset?: ProxyFilterPreset): void {
    this.editing = preset;
    this.labelDraft = preset?.label ?? '';
    this.expressionDraft = preset?.expression ?? '';
    this.deleting = false;
    this.issue = '';
    this.discardRequested = false;
    this.sheetShown = true;
  }

  private closeSheet(dismiss: () => void): void {
    if (this.saving) { return; }
    if (!this.deleting && (this.labelDraft !== (this.editing?.label ?? '') ||
      this.expressionDraft !== (this.editing?.expression ?? ''))) {
      this.discardRequested = !this.discardRequested;
      return;
    }
    dismiss();
  }

  private async saveEditor(): Promise<void> {
    if (this.saving) { return; }
    const original = this.editing;
    const preset = newProxyFilter(this.labelDraft, this.expressionDraft, original?.id);
    const problem = proxyFilterProblem(preset, this.snapshot.presets);
    if (problem !== '') {
      this.issue = this.errorText(problem);
      return;
    }
    const next = this.snapshot.presets.slice();
    if (original === undefined) {
      next.push(preset);
    } else {
      const index = next.findIndex((stored: ProxyFilterPreset): boolean => stored.id === original.id);
      if (index < 0 || next[index].label !== original.label || next[index].expression !== original.expression) {
        this.issue = this.errorText('proxy_filter_conflict');
        return;
      }
      next[index] = preset;
    }
    this.saving = true;
    try {
      if (preset.expression !== original?.expression) {
        const invalidPart = await checkProxyFilter(this.context(), preset.expression);
        if (invalidPart > 0) {
          this.issue = $r('app.string.proxy_filter_regex_error', invalidPart);
          return;
        }
      }
      this.publish(await commitProxyFilters(this.context().filesDir, this.snapshot.revision, next));
      this.sheetShown = false;
      this.toast($r('app.string.proxy_filter_saved'));
    } catch (error) {
      const reason = (error as Error).message;
      if (reason === 'proxy_filter_conflict') { await this.load(); }
      this.issue = this.errorText(reason);
    } finally {
      this.saving = false;
    }
  }

  private visibleSelection(): string[] {
    const ids = new Set<string>(this.visibleIds);
    return this.selectedIds.filter((id: string): boolean => ids.has(id));
  }

  private selectVisible(): void {
    const selected = new Set<string>(this.selectedIds);
    const all = this.visibleIds.every((id: string): boolean => selected.has(id));
    for (const id of this.visibleIds) {
      if (all) { selected.delete(id); } else { selected.add(id); }
    }
    this.selectedIds = Array.from(selected);
  }

  private onRow(preset: ProxyFilterPreset): void {
    if (!this.managing) {
      this.openEditor(preset);
      return;
    }
    this.selectedIds = this.selectedIds.includes(preset.id) ?
      this.selectedIds.filter((id: string): boolean => id !== preset.id) : this.selectedIds.concat(preset.id);
  }

  private async commitList(presets: ProxyFilterPreset[]): Promise<void> {
    if (this.saving) { return; }
    this.saving = true;
    try {
      this.publish(await commitProxyFilters(this.context().filesDir, this.snapshot.revision, presets));
      this.sheetShown = false;
      if (this.count === 0) { this.managing = false; }
      this.toast($r('app.string.proxy_filter_saved'));
    } catch (error) {
      this.refreshRows();
      const reason = (error as Error).message;
      if (reason === 'proxy_filter_conflict') { await this.load(); }
      this.toast(this.errorText(reason));
    } finally {
      this.saving = false;
    }
  }

  private move(from: number, to: number): void {
    if (from === to || from < 0 || to < 0 || from >= this.count || to >= this.count) { return; }
    const next = this.snapshot.presets.slice();
    const moved = next.splice(from, 1)[0];
    next.splice(to, 0, moved);
    this.commitList(next);
  }

  private deleteSelected(): void {
    const selected = new Set<string>(this.visibleSelection());
    this.commitList(this.snapshot.presets.filter((item: ProxyFilterPreset): boolean => !selected.has(item.id)));
  }

  private back(): boolean {
    if (this.sheetShown) {
      this.closeSheet((): void => { this.sheetShown = false; });
      return true;
    }
    if (this.managing) {
      this.managing = false;
      this.selectedIds = [];
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
    DestinationTitle({ titleText: $r('app.string.proxy_filters_title') })
  }

  @Builder
  HeaderButton(icon: Resource, label: Resource, available: boolean, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(icon).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
    }
    .attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
    .accessibilityText(label).enabled(available).onClick(action)
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      if (this.managing) {
        this.HeaderButton($r('sys.symbol.checkmark'), $r('app.string.dash_done'), !this.saving,
          (): void => { this.managing = false; this.selectedIds = []; })
        this.HeaderButton($r('sys.symbol.checkmark_circle'), $r('app.string.added_rules_select_all'),
          this.visibleIds.length > 0 && !this.saving, (): void => this.selectVisible())
        this.HeaderButton($r('sys.symbol.trash'), $r('app.string.action_delete'),
          this.visibleSelection().length > 0 && !this.saving, (): void => {
            this.deleting = true;
            this.sheetShown = true;
          })
      } else {
        this.HeaderButton($r('sys.symbol.magnifyingglass'), $r('app.string.diagnostics_search'),
          !this.loadFailed && !this.loading, (): void => this.toggleSearch())
        if (this.count > 0) {
          this.HeaderButton($r('sys.symbol.square_and_pencil'), $r('app.string.action_edit'), !this.saving,
            (): void => { this.managing = true; })
        }
        this.HeaderButton($r('sys.symbol.plus'), $r('app.string.action_add'),
          !this.loadFailed && !this.loading && !this.saving, (): void => this.openEditor())
      }
    }.height('100%').alignItems(VerticalAlign.Center).padding({ right: PAGE_GUTTER })
  }

  @Builder
  FilterList() {
    List() {
      LazyForEach(this.rows, (item: ProxyFilterRowItem) => {
        ListItem() {
          ProxyFilterRow({ preset: item.preset, first: item.key === this.firstId, last: item.key === this.lastId,
            managing: this.managing, selected: this.selectedIds.includes(item.key),
            sortable: this.query.trim() === '', onTap: (): void => this.onRow(item.preset) })
        }
      }, (item: ProxyFilterRowItem): string => item.key)
        .onMove(this.managing && !this.saving && this.query.trim() === '' ?
          (from: number, to: number): void => this.move(from, to) : undefined)
    }
    .width('100%').layoutWeight(1).enabled(!this.saving).scrollBar(BarState.Off).cachedCount(2)
    .contentStartOffset(12).contentEndOffset(24).padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }

  @Builder
  Content() {
    Column() {
      if (this.searchShown) {
        TextInput({ text: this.query, placeholder: $r('app.string.proxy_filter_search') })
          .height(40).margin({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8 })
          .onChange((text: string): void => { this.query = text; this.refreshRows(); })
      }
      if (this.loading) {
        Column() { LoadingProgress().width(32).height(32).color(this.appStyle.palette.brand) }
          .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.loadFailed || this.visibleIds.length === 0) {
        EmptyState({ icon: $r('sys.symbol.line_3_horizontal'),
          title: this.loadFailed ? $r('app.string.proxy_filter_error') :
            this.query.trim() !== '' ? $r('app.string.diagnostics_no_matches') : $r('app.string.proxy_filter_empty'),
          actionLabel: this.loadFailed ? $r('app.string.dns_override_retry') : '',
          onAction: (): void => { this.load(); } }).layoutWeight(1)
      } else {
        this.FilterList()
      }
    }.width('100%').height('100%')
  }

  @Builder
  SheetBody() {
    Column({ space: 16 }) {
      if (this.deleting) {
        Text($r('app.string.proxy_filter_delete', this.visibleSelection().length)).width('100%')
      } else {
        Column() {
          Row({ space: 12 }) {
            Text($r('app.string.proxy_filter_label')).fontSize(16)
            TextInput({ text: this.labelDraft, placeholder: $r('app.string.profile_field_required') })
              .layoutWeight(1).backgroundColor(Color.Transparent).textAlign(TextAlign.End)
              .maxLength(PROXY_FILTER_LABEL_LIMIT).height(52).enterKeyType(EnterKeyType.Next)
              .onChange((text: string): void => { this.labelDraft = text; this.issue = ''; })
          }.width('100%').padding({ left: 16, right: 12 })
          Divider().margin({ left: 16, right: 16 }).color(this.appStyle.palette.divider)
          Row({ space: 12 }) {
            Text($r('app.string.proxy_filter_regex')).fontSize(16)
            TextInput({ text: this.expressionDraft, placeholder: '(?i)hk|hong\\s*kong' })
              .layoutWeight(1).backgroundColor(Color.Transparent).textAlign(TextAlign.End).fontFamily('monospace')
              .height(52).maxLength(PROXY_FILTER_EXPRESSION_LIMIT)
              .onChange((text: string): void => { this.expressionDraft = text; this.issue = ''; })
              .onSubmit((): void => { this.saveEditor(); })
          }.width('100%').padding({ left: 16, right: 12 })
        }.width('100%').backgroundColor(this.appStyle.palette.cardBackground).borderRadius(16)
        if (this.issue !== '') {
          Text(this.issue).fontSize(14).fontColor($r('app.color.status_error')).width('100%')
        }
      }
      if (this.discardRequested && !this.deleting) {
        Text($r('app.string.added_rules_unsaved')).width('100%')
        Row({ space: 12 }) {
          Button($r('app.string.added_rules_resume')).buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1)
            .onClick((): void => { this.discardRequested = false; })
          Button($r('app.string.added_rules_discard')).role(ButtonRole.ERROR).layoutWeight(1)
            .onClick((): void => { this.sheetShown = false; })
        }.width('100%')
      } else {
        Row({ space: 12 }) {
          Button($r('app.string.action_cancel')).buttonStyle(ButtonStyleMode.NORMAL).layoutWeight(1)
            .onClick((): void => this.closeSheet((): void => { this.sheetShown = false; }))
          if (this.saving) {
            LoadingProgress().width(24).height(24).layoutWeight(1).color(this.appStyle.palette.brand)
          } else if (this.deleting) {
            Button($r('app.string.action_delete')).role(ButtonRole.ERROR).layoutWeight(1)
              .onClick((): void => this.deleteSelected())
          } else {
            Button($r('app.string.action_save')).layoutWeight(1).onClick((): void => { this.saveEditor(); })
          }
        }.width('100%')
      }
    }
    .width('100%').enabled(!this.saving)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
  }

  build() {
    NavDestination() {
      this.Content()
    }
    .title(this.HeaderTitle, { systemMaterial: this.appStyle.regularMaterial() })
    .menus(this.HeaderMenus)
    .padding({ top: this.topInset })
    .backgroundColor(this.appStyle.palette.pageBackground)
    .bindSheet($$this.sheetShown, this.SheetBody, {
      title: { title: this.deleting ? $r('app.string.action_delete') :
        this.editing === undefined ? $r('app.string.action_add') : $r('app.string.action_edit') },
      height: SheetSize.FIT_CONTENT, showClose: true, systemMaterial: this.appStyle.sheetMaterial(),
      onWillDismiss: (action: DismissSheetAction): void => this.closeSheet((): void => action.dismiss())
    })
    .onShown((): void => { this.shown = true; if (!this.saving) { this.load(); } })
    .onHidden((): void => { this.shown = false; })
    .onBackPressed((): boolean => this.back())
  }
}

@ComponentV2
@ReusableV2
struct ProxyFilterRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require preset: ProxyFilterPreset;
  @Param first: boolean = false;
  @Param last: boolean = false;
  @Param managing: boolean = false;
  @Param selected: boolean = false;
  @Param sortable: boolean = false;
  @Event onTap: () => void = () => {};

  build() {
    Column() {
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text(this.preset.label).fontSize(16).fontFamily(this.appStyle.fontFamily)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('sys.color.font_primary'))
          Text(this.preset.expression).fontSize(13).fontFamily('monospace').fontColor(this.appStyle.palette.brand)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.managing) {
          SymbolGlyph(this.selected ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.circle'))
            .fontColor([this.selected ? this.appStyle.palette.brand : $r('sys.color.font_tertiary')]).fontSize(20)
          if (this.sortable) {
            SymbolGlyph($r('sys.symbol.line_3_horizontal')).fontSize(17).fontColor([$r('sys.color.font_tertiary')])
          }
        }
      }.width('100%').constraintSize({ minHeight: 58 }).padding({ left: 16, right: 16, top: 9, bottom: 9 })
      if (!this.last) {
        Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
      }
    }
    .width('100%')
    .backgroundColor(this.selected ? this.appStyle.palette.tileBackground : this.appStyle.palette.cardBackground)
    .borderRadius({ topLeft: this.first ? 22 : 0, topRight: this.first ? 22 : 0,
      bottomLeft: this.last ? 22 : 0, bottomRight: this.last ? 22 : 0 })
    .accessibilitySelected(this.selected).onClick((): void => this.onTap())
  }
}
