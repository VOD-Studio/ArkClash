import { ScrollControls } from '../../components/ScrollControls';
import { common } from '@kit.AbilityKit';
import { decodeProxyLinks, encodeProxyLinks, validateProxyDefinitions } from '../../client/LocalProxyCore';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ScrollDestination } from '../../components/ScrollDestination';
import { EmptyState } from '../../components/EmptyState';
import { ListSource } from '../../components/ListSource';
import { CARD_RADIUS, HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { uiResourceText } from '../../components/ResourceText';
import { emptyLocalProxies, LOCAL_PROXY_COUNT, LOCAL_PROXY_LIMIT, LocalProxy,
  LocalProxySnapshot, localProxyMatches, localProxyName, localProxyProblem, localProxyType,
  ProxyLinkLine } from '../../shared/profiles/LocalProxies';
import { ProxyDefinition } from '../../shared/profiles/LocalProxySchema';
import { buildProxyLinkEdit, commitLocalProxies, readLocalProxies, readProxyLinkPlan }
  from '../../shared/profiles/LocalProxyStore';
import { LocalProxyEditor } from './LocalProxyEditor';
import { proxyIssue } from './LocalProxyLabels';

@ComponentV2
@ReusableV2
struct LocalProxyRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require proxy: LocalProxy;
  @Param first: boolean = false;
  @Param last: boolean = false;
  @Param active: boolean = false;
  @Param issue: string = '';
  @Param interactive: boolean = true;
  @Event onOpen: () => void = () => {};
  @Event onCheck: (checked: boolean) => void = (_checked: boolean): void => {};
  @Event onIssue: () => void = () => {};

  build() {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        Text(localProxyName(this.proxy) || '–').fontSize(16).fontColor($r('sys.color.font_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(localProxyType(this.proxy)).fontSize(13).fontColor($r('sys.color.font_secondary')).maxLines(1)
      }.width('100%').height(60).layoutWeight(1).alignItems(HorizontalAlign.Start).justifyContent(FlexAlign.Center)
        .accessibilityLevel('yes').accessibilityText(localProxyName(this.proxy)).onClick((): void => this.onOpen())
      if (this.issue !== '') {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle')).fontSize(20)
            .fontColor([this.issue === 'local_proxy_core_unavailable' ? $r('sys.color.font_secondary') :
              $r('app.color.status_error')])
        }.width(36).height(36).backgroundColor(Color.Transparent).accessibilityText(proxyIssue(this.issue))
          .onClick((): void => this.onIssue())
      }
      Checkbox({ name: this.proxy.id }).select(this.active).shape(CheckBoxShape.CIRCLE)
        .selectedColor(this.appStyle.palette.brand).width(24).height(24)
        .accessibilityText(localProxyName(this.proxy)).onChange((checked: boolean): void => this.onCheck(checked))
    }.width('100%').height(60).padding({ left: 16, right: 14 }).enabled(this.interactive)
      .backgroundColor(this.active ? this.appStyle.palette.selectionTonal : this.appStyle.palette.cardBackground)
      .borderRadius({ topLeft: this.first ? CARD_RADIUS : 4, topRight: this.first ? CARD_RADIUS : 4,
        bottomLeft: this.last ? CARD_RADIUS : 4, bottomRight: this.last ? CARD_RADIUS : 4 })
  }
}

@ComponentV2
export struct LocalProxiesPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param foreground: boolean = true;
  @Local private snapshot: LocalProxySnapshot = emptyLocalProxies();
  @Local private selected: string[] = [];
  @Local private issues: Map<string, string> = new Map<string, string>();
  @Local private loading: boolean = true;
  @Local private failed: boolean = false;
  @Local private busy: boolean = false;
  @Local private search: boolean = false;
  @Local private query: string = '';
  @Local private visible: LocalProxy[] = [];
  @Local private editShown: boolean = false;
  @Local private editorProxy: LocalProxy | undefined = undefined;
  @Local private editorDismiss: number = 0;
  @Local private deleteShown: boolean = false;
  @Local private deleted: LocalProxy[] = [];
  @Local private linksShown: boolean = false;
  @Local private linksText: string = '';
  @Local private linksOriginal: string = '';
  @Local private linksError: ResourceStr = '';
  @Local private linksDiscard: boolean = false;
  @Local private linksRemoved: string = '';
  @Local private linksAdded: string = '';
  private linksSnapshot: LocalProxySnapshot = emptyLocalProxies();
  private encodedLinks: string[] = [];
  private linksProposed: LocalProxy[] | undefined = undefined;
  private source: ListSource<LocalProxy> = new ListSource<LocalProxy>();
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private shown: boolean = false;
  private generation: number = 0;

  private toast(message: ResourceStr): void {
    if (this.shown && this.foreground) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }

  private showRows(): void {
    this.visible = this.snapshot.proxies.filter((item: LocalProxy): boolean => localProxyMatches(item, this.query));
    this.source.replace(this.visible);
  }

  private accept(snapshot: LocalProxySnapshot): void {
    this.snapshot = snapshot;
    const ids = new Set<string>(snapshot.proxies.map((item: LocalProxy): string => item.id));
    this.selected = this.selected.filter((id: string): boolean => ids.has(id));
    this.showRows();
    this.validate(snapshot, ++this.generation);
  }

  private async refresh(): Promise<void> {
    const generation = ++this.generation;
    this.failed = false;
    try {
      const snapshot = await readLocalProxies(this.context.filesDir);
      if (this.shown && this.generation === generation) { this.accept(snapshot); }
    } catch (error) {
      if (this.shown && this.generation === generation) { this.failed = true; }
    } finally {
      this.loading = false;
    }
  }

  private async validate(snapshot: LocalProxySnapshot, generation: number): Promise<void> {
    const state = new Map<string, string>();
    const candidates: LocalProxy[] = [];
    for (const item of snapshot.proxies) {
      const problem = localProxyProblem(item.definition);
      if (problem !== '') { state.set(item.id, problem); }
      else { candidates.push(item); }
    }
    this.issues = state;
    try {
      const result = await validateProxyDefinitions(this.context, candidates.map((item: LocalProxy): ProxyDefinition =>
        item.definition));
      candidates.forEach((item: LocalProxy, index: number): void => {
        if (result[index] !== '') { state.set(item.id, result[index] ?? 'local_proxy_core_unavailable'); }
      });
    } catch (error) {
      candidates.forEach((item: LocalProxy): void => { state.set(item.id, 'local_proxy_core_unavailable'); });
    }
    if (this.shown && this.generation === generation) { this.issues = new Map<string, string>(state); }
  }

  @Monitor('foreground')
  foregroundChanged(): void { if (this.shown && this.foreground && !this.busy) { this.refresh(); } }

  private setSelection(item: LocalProxy, checked: boolean): void {
    if (this.selected.includes(item.id) === checked) { return; }
    this.selected = checked ? this.selected.concat(item.id) :
      this.selected.filter((id: string): boolean => id !== item.id);
  }

  private selectedVisible(): LocalProxy[] {
    return this.visible.filter((item: LocalProxy): boolean => this.selected.includes(item.id));
  }

  private selectVisible(): void {
    const ids = new Set<string>(this.visible.map((item: LocalProxy): string => item.id));
    if (this.selectedVisible().length === ids.size) {
      this.selected = this.selected.filter((id: string): boolean => !ids.has(id));
    } else {
      this.selected = Array.from(new Set<string>(this.selected.concat(Array.from(ids))));
    }
  }

  private openEditor(item?: LocalProxy): void {
    if (this.busy) { return; }
    this.editorDismiss = 0;
    this.editorProxy = item;
    this.editShown = true;
  }

  private openRow(item: LocalProxy): void {
    if (this.selected.length > 0) { this.setSelection(item, !this.selected.includes(item.id)); }
    else { this.openEditor(item); }
  }

  private editorSaved(snapshot: LocalProxySnapshot, message: ResourceStr): void {
    this.editShown = false;
    this.accept(snapshot);
    this.toast(message);
  }

  private async remove(): Promise<void> {
    if (this.busy) { return; }
    const ids = new Set<string>(this.deleted.map((item: LocalProxy): string => item.id));
    this.busy = true;
    try {
      const updated = await commitLocalProxies(this.context.filesDir, this.snapshot,
        this.snapshot.proxies.filter((item: LocalProxy): boolean => !ids.has(item.id)));
      this.deleteShown = false;
      this.accept(updated);
      this.toast($r('app.string.local_proxy_deleted'));
    } catch (error) {
      this.toast(proxyIssue((error as Error).message));
      this.deleteShown = false;
      await this.refresh();
    } finally { this.busy = false; }
  }

  private async move(from: number, to: number): Promise<void> {
    if (this.busy || this.query.trim() !== '' || this.snapshot.proxies[from] === undefined ||
      this.snapshot.proxies[to] === undefined || from === to) { this.showRows(); return; }
    const ordered = this.snapshot.proxies.slice();
    const item = ordered.splice(from, 1)[0];
    ordered.splice(to, 0, item);
    this.busy = true;
    try {
      const updated = await commitLocalProxies(this.context.filesDir, this.snapshot, ordered);
      this.accept(updated);
    } catch (error) {
      this.toast(proxyIssue((error as Error).message));
      this.showRows();
      await this.refresh();
    } finally { this.busy = false; }
  }

  private async openLinks(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.linksSnapshot = this.snapshot;
    try {
      const definitions = this.linksSnapshot.proxies.map((item: LocalProxy): ProxyDefinition => item.definition);
      this.encodedLinks = await encodeProxyLinks(this.context, definitions);
      if (this.encodedLinks.length !== definitions.length) { throw new Error('local_proxy_core_unavailable'); }
      if (this.shown) {
        this.linksOriginal = this.encodedLinks.filter((line: string): boolean => line !== '').join('\n');
        this.linksText = this.linksOriginal;
        this.linksError = '';
        this.linksDiscard = false;
        this.linksRemoved = '';
        this.linksAdded = '';
        this.linksProposed = undefined;
        this.linksShown = true;
      }
    } catch (error) { this.toast(proxyIssue((error as Error).message)); }
    finally { this.busy = false; }
  }

  private async submitLinks(): Promise<void> {
    if (this.busy) { return; }
    if (this.linksText === this.linksOriginal) { this.linksShown = false; return; }
    this.busy = true;
    this.linksError = '';
    try {
      if (this.linksText.length > LOCAL_PROXY_LIMIT) { throw new Error('local_proxy_input'); }
      const plan = await readProxyLinkPlan(this.linksSnapshot, this.encodedLinks, this.linksText);
      if (plan.lines.length > LOCAL_PROXY_COUNT) { throw new Error('local_proxy_input'); }
      const pending = plan.lines.filter((line: ProxyLinkLine): boolean => line.kept === undefined);
      const oldLinks = new Map<string, string>();
      this.linksSnapshot.proxies.forEach((item: LocalProxy, index: number): void => {
        oldLinks.set(item.id, this.encodedLinks[index]);
      });
      const decoded = await decodeProxyLinks(this.context,
        pending.map((line: ProxyLinkLine): string => line.link));
      const byLine = new Map<number, ProxyDefinition[]>();
      for (let index = 0; index < pending.length; index++) {
        if (!decoded[index]?.length) { throw new Error(`local_proxy_line|${pending[index].number}|local_proxy_link`); }
        byLine.set(pending[index].number, decoded[index]);
      }
      const previous = await decodeProxyLinks(this.context,
        plan.dropped.map((item: LocalProxy): string => oldLinks.get(item.id) ?? ''));
      const original = new Map<string, ProxyDefinition>();
      plan.dropped.forEach((item: LocalProxy, index: number): void => {
        if (previous[index]?.length === 1) { original.set(item.id, previous[index][0]); }
      });
      const next = await buildProxyLinkEdit(this.linksSnapshot, this.encodedLinks, plan, byLine, original);
      const old = new Map<string, LocalProxy>();
      this.linksSnapshot.proxies.forEach((item: LocalProxy): void => { old.set(item.id, item); });
      const changed = next.filter((item: LocalProxy): boolean => old.get(item.id)?.revision !== item.revision);
      const result = await validateProxyDefinitions(this.context,
        changed.map((item: LocalProxy): ProxyDefinition => item.definition), true);
      const firstIssue = result.findIndex((problem: string): boolean => problem !== '');
      if (result.length !== changed.length) { throw new Error('local_proxy_core_unavailable'); }
      if (firstIssue >= 0) {
        let position = 0;
        for (const line of pending) {
          position += byLine.get(line.number)?.length ?? 0;
          if (firstIssue < position) { throw new Error(`local_proxy_line|${line.number}|${result[firstIssue]}`); }
        }
        throw new Error(result[firstIssue]);
      }
      const nextIds = new Set<string>(next.map((item: LocalProxy): string => item.id));
      const removed = plan.dropped.filter((item: LocalProxy): boolean => !nextIds.has(item.id));
      if (removed.length > 0) {
        this.linksProposed = next;
        this.linksRemoved = removed.map(localProxyName).join(', ');
        this.linksAdded = next.filter((item: LocalProxy): boolean => !old.has(item.id)).map(localProxyName).join(', ');
      } else { await this.commitLinks(next); }
    } catch (error) {
      const code = (error as Error).message.split('|');
      this.linksError = code[0] === 'local_proxy_line' ?
        $r('app.string.local_proxy_line', Number(code[1]), uiResourceText(this.getUIContext(), proxyIssue(code[2]))) :
        proxyIssue(code[0]);
    } finally { this.busy = false; }
  }

  private async commitLinks(next: LocalProxy[]): Promise<void> {
    this.busy = true;
    try {
      const updated = await commitLocalProxies(this.context.filesDir, this.linksSnapshot, next);
      this.linksShown = false;
      this.accept(updated);
      this.toast($r('app.string.local_proxy_saved'));
    } catch (error) {
      this.linksProposed = undefined;
      this.linksError = proxyIssue((error as Error).message);
    } finally { this.busy = false; }
  }

  @Builder
  Title() { DestinationTitle({ titleText: $r('app.string.local_proxy_title') }) }

  @Builder
  HeaderButton(icon: Resource, label: Resource, active: boolean, action: () => void) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(icon).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
    }.attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText(label).enabled(active).onClick((): void => action())
  }

  @Builder
  AddMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.action_add') }).onClick((): void => this.openEditor())
      MenuItem({ content: $r('app.string.local_proxy_quick_edit') }).onClick((): void => { this.openLinks(); })
    }
  }

  @Builder
  Header() {
    Row({ space: HEADER_GAP }) {
      this.HeaderButton(this.search ? $r('sys.symbol.xmark') : $r('sys.symbol.magnifyingglass'),
        this.search ? $r('app.string.proxy_search_close') : $r('app.string.proxy_search'),
        !this.loading && !this.failed && !this.busy, (): void => {
          this.search = !this.search;
          if (!this.search) { this.query = ''; this.showRows(); }
        })
      if (this.selected.length > 0) {
        this.HeaderButton($r('sys.symbol.checkmark'), $r('app.string.added_rules_select_all'),
          !this.busy && this.visible.length > 0, (): void => this.selectVisible())
        this.HeaderButton($r('sys.symbol.trash'), $r('app.string.action_delete'),
          !this.busy && this.selectedVisible().length > 0, (): void => {
            this.deleted = this.selectedVisible();
            this.deleteShown = true;
          })
      } else {
        Button({ type: ButtonType.Circle }) {
          if (this.busy) {
            LoadingProgress().width(20).height(20).color(this.appStyle.palette.brand)
          } else {
            SymbolGlyph($r('sys.symbol.plus')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
          }
        }.attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
          .enabled(!this.loading && !this.failed && !this.busy)
          .accessibilityText($r('app.string.action_add')).bindMenu(this.AddMenu)
      }
    }.height('100%').alignItems(VerticalAlign.Center).padding({ right: PAGE_GUTTER })
  }

  @Builder
  Item(item: LocalProxy) {
    LocalProxyRow({ proxy: item, first: this.visible[0]?.id === item.id,
      last: this.visible[this.visible.length - 1]?.id === item.id, active: this.selected.includes(item.id),
      issue: this.issues.get(item.id) ?? '', interactive: !this.busy,
      onOpen: (): void => this.openRow(item), onCheck: (checked: boolean): void => this.setSelection(item, checked),
      onIssue: (): void => this.toast(proxyIssue(this.issues.get(item.id) ?? '')) })
  }

  @Builder
  Rows() {
    List({ space: 2 }) {
      if (this.query.trim() === '') {
        LazyForEach(this.source, (item: LocalProxy) => {
          ListItem() { this.Item(item) }
        }, (item: LocalProxy): string => `${item.id}:${item.revision}`)
          .onMove((from: number, to: number): void => { this.move(from, to); })
      } else {
        LazyForEach(this.source, (item: LocalProxy) => {
          ListItem() { this.Item(item) }
        }, (item: LocalProxy): string => `${item.id}:${item.revision}`)
      }
    }.width('100%').layoutWeight(1).padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
      .contentStartOffset(12).contentEndOffset(24).cachedCount(2, true).scrollBar(BarState.Off)
      .clipContent(ContentClipMode.SAFE_AREA)
  }

  @Builder
  DeleteSheet() {
    Column({ space: 14 }) {
      Text(this.deleted.map(localProxyName).join(', ')).width('100%').maxLines(5)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).fontSize(15)
      Button($r('app.string.action_delete'), { role: ButtonRole.ERROR }).width('100%').height(48)
        .enabled(!this.busy).onClick((): void => { this.remove(); })
      Button($r('app.string.action_cancel')).width('100%').height(48)
        .enabled(!this.busy).onClick((): void => { this.deleteShown = false; })
    }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }

  @Builder
  LinksSheet() {
    Column({ space: 12 }) {
      if (this.linksProposed !== undefined) {
        Text($r('app.string.local_proxy_links_remove', this.linksRemoved)).width('100%').maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.status_error'))
        if (this.linksAdded !== '') {
          Text($r('app.string.local_proxy_links_add', this.linksAdded)).width('100%').maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      TextArea({ text: this.linksText, placeholder: 'vless://…' }).fontSize(14).width('100%').layoutWeight(1)
        .maxLength(LOCAL_PROXY_LIMIT).enabled(!this.busy && this.linksProposed === undefined)
        .onChange((text: string): void => { this.linksText = text; this.linksError = ''; this.linksDiscard = false; })
      if (this.linksError !== '') { Text(this.linksError).fontColor($r('app.color.status_error')).width('100%') }
      if (this.linksDiscard) { Text($r('app.string.added_rules_unsaved')).width('100%') }
      Row({ space: 12 }) {
        Button(this.linksDiscard ? $r('app.string.added_rules_discard') : $r('app.string.action_cancel'))
          .layoutWeight(1).height(48).buttonStyle(ButtonStyleMode.NORMAL).enabled(!this.busy)
          .onClick((): void => {
            if (this.linksProposed !== undefined) { this.linksProposed = undefined; }
            else { this.closeLinks(); }
          })
        Button(this.linksDiscard ? $r('app.string.added_rules_resume') : $r('app.string.action_save'))
          .layoutWeight(1).height(48).enabled(!this.busy)
          .onClick((): void => {
            if (this.linksDiscard) { this.linksDiscard = false; }
            else if (this.linksProposed !== undefined) { this.commitLinks(this.linksProposed); }
            else { this.submitLinks(); }
          })
      }.width('100%')
    }.width('100%').height('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }

  private closeLinks(): void {
    if (this.busy) { return; }
    if (this.linksProposed !== undefined) { this.linksProposed = undefined; return; }
    if (this.linksText === this.linksOriginal || this.linksDiscard) { this.linksShown = false; }
    else { this.linksDiscard = true; }
  }

  @Builder
  EditorSheet() {
    LocalProxyEditor({ proxy: this.editorProxy, snapshot: this.snapshot, foreground: this.foreground,
      dismissRequest: this.editorDismiss,
      onClose: (): void => { this.editShown = false; },
      onSaved: (snapshot: LocalProxySnapshot, message: ResourceStr): void => this.editorSaved(snapshot, message) })
  }

  @Builder
  SearchControl() {
    if (this.search) {
      TextInput({ text: this.query, placeholder: $r('app.string.local_proxy_search') })
        .height(40).margin({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8 })
        .onChange((text: string): void => { this.query = text; this.showRows(); })
    }
  }

  build() {
    ScrollDestination({
      heading: (): void => this.Title(),
      actions: (): void => this.Header(),
      pageShown: (): void => { this.shown = true; this.refresh(); },
      pageHidden: (): void => { this.shown = false; this.generation++; },
      handleBack: (): boolean => {
        if (this.selected.length > 0) { this.selected = []; return true; }
        if (this.search) { this.search = false; this.query = ''; this.showRows(); return true; }
        return this.busy;
      }
    }) {
      Stack() {
        ScrollControls({ controls: (): void => this.SearchControl() }) {
          if (this.loading) {
            Column() { LoadingProgress().width(28).height(28).color(this.appStyle.palette.brand) }
              .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          } else if (this.failed || this.visible.length === 0) {
            EmptyState({ icon: $r('sys.symbol.connection'), title: this.failed ? $r('app.string.local_proxy_store') :
              this.query.trim() === '' ? $r('app.string.local_proxy_empty') : $r('app.string.diagnostics_no_matches'),
              actionLabel: this.failed ? $r('app.string.action_retry') :
                this.query.trim() === '' ? $r('app.string.action_add') : '',
              onAction: (): void => { if (this.failed) { this.refresh(); } else { this.openEditor(); } } })
              .layoutWeight(1)
          } else { this.Rows() }
        }
        Column().bindSheet($$this.editShown, this.EditorSheet, {
          title: { title: this.editorProxy === undefined ? $r('app.string.local_proxy_add') :
            $r('app.string.local_proxy_edit') }, height: SheetSize.LARGE, showClose: true,
          systemMaterial: this.appStyle.sheetMaterial(),
          onWillDismiss: (_action: DismissSheetAction): void => { this.editorDismiss++; }
        })
        Column().bindSheet($$this.deleteShown, this.DeleteSheet, {
          title: { title: $r('app.string.action_delete') }, height: SheetSize.FIT_CONTENT, showClose: true,
          systemMaterial: this.appStyle.sheetMaterial(),
          onWillDismiss: (action: DismissSheetAction): void => { if (!this.busy) { action.dismiss(); } }
        })
        Column().bindSheet($$this.linksShown, this.LinksSheet, {
          title: { title: $r('app.string.local_proxy_quick_edit') }, height: SheetSize.LARGE, showClose: true,
          systemMaterial: this.appStyle.sheetMaterial(),
          onWillDismiss: (_action: DismissSheetAction): void => this.closeLinks()
        })
      }.width('100%').height('100%')
    }
  }
}
