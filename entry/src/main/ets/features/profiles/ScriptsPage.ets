import { common } from '@kit.AbilityKit';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ScrollDestination } from '../../components/ScrollDestination';
import { EmptyState } from '../../components/EmptyState';
import { formatUpdatedAgo } from '../../components/Format';
import { ListSource } from '../../components/ListSource';
import { CARD_RADIUS, HEADER_ACTION, HEADER_ICON_SIZE, HEADER_GAP, PAGE_GUTTER } from '../../components/Theme';
import { applyConfigScript } from '../../shared/profiles/ScriptApply';
import { fetchConfigScript } from '../../client/ScriptDownloads';
import { ConfigScript, ConfigScriptsSnapshot, emptyConfigScripts, readConfigScripts,
  readScriptText, removeConfigScript, reorderConfigScripts, saveConfigScript } from '../../shared/profiles/Scripts';
import { readListAsync } from '../../shared/profiles/Store';
import { pickDocumentFile, documentFileName } from '../../client/DocumentPicker';
import { configScriptError } from './ScriptMessages';

@ComponentV2
@ReusableV2
struct ConfigScriptRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require item: ConfigScript;
  @Param @Require first: boolean;
  @Param @Require last: boolean;
  @Param sorting: boolean = false;
  @Param updating: boolean = false;
  @Param now: number = 0;
  @Event onEdit: () => void = (): void => {};
  @Event onUrl: () => void = (): void => {};
  @Event onSync: () => void = (): void => {};
  @Event onDelete: () => void = (): void => {};

  @Builder
  RowActions() {
    Menu() {
      MenuItem({ content: $r('app.string.action_edit') }).onClick((): void => this.onEdit())
      if (this.item.url !== '') {
        MenuItem({ content: $r('app.string.script_url') }).onClick((): void => this.onUrl())
        MenuItem({ content: $r('app.string.script_sync') }).onClick((): void => this.onSync())
      }
      MenuItem({ content: $r('app.string.action_delete') })
        .contentFontColor($r('app.color.status_error')).onClick((): void => this.onDelete())
    }
  }

  @Builder
  RowLabel() {
    Column({ space: 4 }) {
      Text(this.item.name).fontFamily(this.appStyle.fontFamily).fontSize(16).fontWeight(500)
        .fontColor($r('sys.color.font_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.item.url === '' ? $r('app.string.script_local') : $r('app.string.script_remote'))
        .fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('sys.color.font_secondary'))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  MainRow() {
    Row({ space: 12 }) {
      if (this.sorting) {
        Row() { this.RowLabel() }.layoutWeight(1)
      } else {
        Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.NORMAL }) {
          this.RowLabel()
        }.layoutWeight(1).height(64).padding(0).backgroundColor(Color.Transparent)
          .enabled(!this.updating).onClick((): void => this.onEdit())
      }
      if (this.updating) {
        LoadingProgress().width(22).height(22).color(this.appStyle.palette.brand)
      } else if (this.sorting) {
        SymbolGlyph($r('sys.symbol.line_3_horizontal')).fontSize(20).fontColor([$r('sys.color.font_secondary')])
          .accessibilityText($r('app.string.profile_sort'))
      } else {
        Text(formatUpdatedAgo(this.item.updatedAt, this.now)).fontSize(13).fontColor($r('sys.color.font_secondary'))
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.NORMAL }) {
          SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(20).fontColor([$r('sys.color.font_secondary')])
        }
        .width(40).height(40).backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.action_more')).bindMenu(this.RowActions)
      }
    }
    .width('100%').height(64)
    .padding({ left: 16, right: this.sorting || this.updating ? 16 : 4 })
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius({ topLeft: this.first ? CARD_RADIUS : 4, topRight: this.first ? CARD_RADIUS : 4,
      bottomLeft: this.last ? CARD_RADIUS : 4, bottomRight: this.last ? CARD_RADIUS : 4 })
  }

  build() {
    Column() {
      if (this.sorting || this.updating) {
        this.MainRow()
      } else {
        Column() { this.MainRow() }.bindContextMenu(this.RowActions, ResponseType.LongPress)
      }
    }.width('100%')
  }
}

let cachedConfigScripts: ConfigScriptsSnapshot | undefined = undefined;

@ComponentV2
export struct ScriptsPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param foreground: boolean = true;
  @Event onEdit: (id: string) => void = (_id: string): void => {};
  @Local private snapshot: ConfigScriptsSnapshot = cachedConfigScripts ?? emptyConfigScripts();
  @Local private loading: boolean = cachedConfigScripts === undefined;
  @Local private loadFailed: boolean = false;
  @Local private busy: boolean = false;
  @Local private sorting: boolean = false;
  @Local private activeScript: string = '';
  @Local private now: number = Date.now();
  @Local private urlShown: boolean = false;
  @Local private urlDraft: string = '';
  @Local private urlError: ResourceStr = '';
  @Local private urlScript: ConfigScript | undefined = undefined;
  @Local private deleteShown: boolean = false;
  @Local private toDelete: ConfigScript | undefined = undefined;
  @Local private affected: string = '';
  private rows: ListSource<ConfigScript> = new ListSource<ConfigScript>();
  private shown: boolean = false;
  private readId: number = 0;
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    if (cachedConfigScripts !== undefined) {
      this.accept(cachedConfigScripts);
    }
  }

  private toast(message: ResourceStr): void {
    if (this.shown && this.foreground) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }

  private accept(store: ConfigScriptsSnapshot): void {
    this.readId++;
    cachedConfigScripts = store;
    this.snapshot = store;
    this.rows.replace(store.scripts);
    this.now = Date.now();
  }

  private async refresh(): Promise<void> {
    const read = ++this.readId;
    const silent = cachedConfigScripts !== undefined;
    this.loadFailed = false;
    try {
      const store = await readConfigScripts(this.context.filesDir);
      if (read === this.readId) { this.accept(store); }
    } catch (error) {
      if (read === this.readId && !silent) { this.loadFailed = true; }
    } finally { this.loading = false; }
  }

  @Monitor('foreground')
  foregroundChanged(): void { if (this.shown && this.foreground) { this.refresh(); } }

  private async importFile(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      const uri = await pickDocumentFile(this.context);
      if (uri === undefined) { return; }
      const source = await readScriptText(uri);
      this.accept(await saveConfigScript(this.context.filesDir, undefined, documentFileName(uri), source, '', true));
      this.toast($r('app.string.script_saved'));
    } catch (error) { this.toast(configScriptError(error as Object)); }
    finally { this.busy = false; }
  }

  private openUrl(item?: ConfigScript): void {
    if (this.busy) { return; }
    this.urlScript = item;
    this.urlDraft = item?.url ?? '';
    this.urlError = '';
    this.urlShown = true;
  }

  private async sync(url: string, item?: ConfigScript): Promise<void> {
    if (this.busy) { return; }
    if (this.urlShown && item !== undefined && url.trim() === item.url) { this.urlShown = false; return; }
    this.busy = true;
    this.activeScript = item?.id ?? '';
    this.urlError = '';
    try {
      const store = await fetchConfigScript(this.context, url, item);
      this.accept(store);
      this.urlShown = false;
      if (item !== undefined) {
        try {
          const applied = await applyConfigScript(this.context.filesDir, store, '', item.id);
          this.toast(applied ? $r('app.string.script_applied') : $r('app.string.script_synced'));
        } catch (error) { this.toast($r('app.string.script_saved_apply_error', configScriptError(error as Object))); }
      } else { this.toast($r('app.string.script_saved')); }
    } catch (error) {
      if (this.urlShown) { this.urlError = configScriptError(error as Object); }
      else { this.toast(configScriptError(error as Object)); }
    } finally { this.busy = false; this.activeScript = ''; }
  }

  private async openDelete(item: ConfigScript): Promise<void> {
    if (this.busy) { return; }
    try {
      const store = await readConfigScripts(this.context.filesDir);
      const list = await readListAsync(this.context.filesDir);
      this.affected = list.profiles.filter((profile): boolean => store.bindings.some((binding): boolean =>
        binding.profile === profile.id && binding.scriptId === item.id)).map((profile): string => profile.name).join('、');
      this.toDelete = item;
      this.deleteShown = true;
    } catch (error) { this.toast(configScriptError(error as Object)); }
  }

  private async remove(): Promise<void> {
    const item = this.toDelete;
    if (item === undefined || this.busy) { return; }
    this.busy = true;
    try {
      this.accept(await removeConfigScript(this.context.filesDir, item));
      this.deleteShown = false;
      this.toast($r('app.string.script_deleted'));
    } catch (error) { this.toast(configScriptError(error as Object)); }
    finally { this.busy = false; }
  }

  private async move(from: number, to: number): Promise<void> {
    const scripts = this.snapshot.scripts;
    if (this.busy || from === to || scripts[from] === undefined || scripts[to] === undefined) { return; }
    this.busy = true;
    try { this.accept(await reorderConfigScripts(this.context.filesDir, scripts[from], scripts[to])); }
    catch (error) { this.toast(configScriptError(error as Object)); }
    finally { this.busy = false; }
  }

  @Builder
  HeaderTitle() { DestinationTitle({ titleText: $r('app.string.script_title') }) }

  @Builder
  AddMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.script_new') }).onClick((): void => this.onEdit(''))
      MenuItem({ content: $r('app.string.script_import_url') }).onClick((): void => this.openUrl())
      MenuItem({ content: $r('app.string.script_import_file') }).onClick((): void => { this.importFile(); })
    }
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      if (this.snapshot.scripts.length > 1) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(this.sorting ? $r('sys.symbol.checkmark') : $r('sys.symbol.sort')).fontSize(HEADER_ICON_SIZE)
            .fontColor([$r('sys.color.font_primary')])
        }.attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
          .accessibilityText($r('app.string.profile_sort')).enabled(!this.busy)
          .onClick((): void => { this.sorting = !this.sorting; })
      }
      Button({ type: ButtonType.Circle }) {
        if (this.busy && this.activeScript === '') {
          LoadingProgress().width(20).height(20).color(this.appStyle.palette.brand)
        } else {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
        }
      }.attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
        .accessibilityText($r('app.string.action_add')).enabled(!this.busy && !this.loading && !this.loadFailed && !this.sorting)
        .bindMenu(this.AddMenu)
    }.height('100%').alignItems(VerticalAlign.Center).padding({ right: PAGE_GUTTER })
  }

  @Builder
  UrlSheet() {
    Column({ space: 14 }) {
      TextInput({ text: this.urlDraft, placeholder: 'https://' }).type(InputType.URL)
        .maxLength(2048).width('100%').enabled(!this.busy).onChange((text: string): void => { this.urlDraft = text; })
      if (this.urlScript !== undefined) {
        Text($r('app.string.script_remote_edit_hint')).fontSize(13).fontColor($r('sys.color.font_secondary'))
      }
      if (this.urlError !== '') { Text(this.urlError).fontSize(14).fontColor($r('app.color.status_error')) }
      Button(this.urlScript === undefined ? $r('app.string.script_import_url') : $r('app.string.script_sync'))
        .width('100%').height(48).enabled(!this.busy && this.urlDraft.trim() !== '')
        .onClick((): void => { this.sync(this.urlDraft, this.urlScript); })
    }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }

  @Builder
  DeleteSheet() {
    Column({ space: 16 }) {
      if (this.toDelete !== undefined) { Text(this.toDelete.name).fontSize(16).width('100%') }
      if (this.affected !== '') {
        Text($r('app.string.script_delete_bound', this.affected)).fontSize(14).fontColor($r('sys.color.font_secondary'))
      }
      Button($r('app.string.action_delete'), { role: ButtonRole.ERROR }).width('100%').height(48)
        .enabled(!this.busy).onClick((): void => { this.remove(); })
      Button($r('app.string.action_cancel')).width('100%').height(48).enabled(!this.busy)
        .onClick((): void => { this.deleteShown = false; })
    }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }

  @Builder
  ScriptListRow(item: ConfigScript) {
    ConfigScriptRow({ item: item, first: this.snapshot.scripts[0]?.id === item.id,
      last: this.snapshot.scripts[this.snapshot.scripts.length - 1]?.id === item.id,
      sorting: this.sorting, updating: this.activeScript === item.id, now: this.now,
      onEdit: (): void => { if (!this.busy && !this.sorting) { this.onEdit(item.id); } },
      onUrl: (): void => { if (!this.sorting) { this.openUrl(item); } },
      onSync: (): void => { if (!this.sorting) { this.sync(item.url, item); } },
      onDelete: (): void => { if (!this.sorting) { this.openDelete(item); } } })
  }

  build() {
    ScrollDestination({
      heading: (): void => this.HeaderTitle(),
      actions: (): void => this.HeaderMenus(),
      pageShown: (): void => { this.shown = true; this.refresh(); },
      pageHidden: (): void => { this.shown = false; }
    }) {
      Column() {
        Column() {
        if (this.loading) {
          LoadingProgress().width(28).height(28).margin({ top: 20 })
        } else if (this.loadFailed) {
          Text($r('app.string.script_err_store')).margin(16)
          Button($r('app.string.action_retry')).onClick((): void => { this.refresh(); })
        } else if (this.snapshot.scripts.length === 0) {
          EmptyState({ icon: $r('sys.symbol.doc_text'), title: $r('app.string.script_no_items') }).layoutWeight(1)
        } else {
          List({ space: 2 }) {
            if (this.sorting) {
              LazyForEach(this.rows, (item: ConfigScript) => {
                ListItem() { this.ScriptListRow(item) }
              }, (item: ConfigScript): string => item.id)
                .onMove((from: number, to: number): void => { this.move(from, to); })
            } else {
              LazyForEach(this.rows, (item: ConfigScript) => {
                ListItem() { this.ScriptListRow(item) }
              }, (item: ConfigScript): string => item.id)
            }
          }.width('100%').layoutWeight(1).padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
            .contentStartOffset(16).contentEndOffset(24).cachedCount(2, true).scrollBar(BarState.Off)
            .clipContent(ContentClipMode.SAFE_AREA)
        }
      }.width('100%').height('100%')
      .bindSheet($$this.urlShown, this.UrlSheet(), { height: SheetSize.FIT_CONTENT,
        title: { title: this.urlScript === undefined ? $r('app.string.script_import_url') : $r('app.string.script_url') },
        showClose: true, systemMaterial: this.appStyle.sheetMaterial(),
        onWillDismiss: (action: DismissSheetAction): void => { if (!this.busy) { action.dismiss(); } } })
      }.width('100%').height('100%')
      .bindSheet($$this.deleteShown, this.DeleteSheet(), { height: SheetSize.FIT_CONTENT,
        title: { title: $r('app.string.script_delete_title') }, showClose: true, systemMaterial: this.appStyle.sheetMaterial(),
        onWillDismiss: (action: DismissSheetAction): void => { if (!this.busy) { action.dismiss(); } } })
    }
  }
}
