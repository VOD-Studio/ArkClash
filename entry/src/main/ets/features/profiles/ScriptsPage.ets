import { common } from '@kit.AbilityKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { KeyedListSource } from '../../components/KeyedListSource';
import { ScrollDestination } from '../../components/ScrollDestination';
import { SETTLE_SPRING } from '../../components/SheetParts';
import { HEADER_ACTION, HEADER_ICON_SIZE, HEADER_GAP, PAGE_GUTTER } from '../../components/Theme';
import { applyConfigScript } from '../../shared/profiles/ScriptApply';
import { fetchConfigScript } from '../../client/ScriptDownloads';
import { ConfigScript, ConfigScriptsSnapshot, emptyConfigScripts, readConfigScripts,
  readScriptText, removeConfigScript, reorderConfigScripts, saveConfigScript } from '../../shared/profiles/Scripts';
import { readListAsync } from '../../shared/profiles/Store';
import { pickDocumentFile, documentFileName } from '../../client/DocumentPicker';
import { configScriptError } from './ScriptMessages';
import { ScriptDeleteSheet } from './ScriptDeleteSheet';
import { ScriptRow } from './ScriptRow';
import { ScriptsEmpty } from './ScriptsEmpty';
import { ScriptUrlDraft, ScriptUrlSheet } from './ScriptUrlSheet';

/**
 * 列表里的一项。重新读取后按 id 复用同一个对象、只替换 script：
 * 同步、改名时行原地刷新，不重建，右侧的转圈和更多按钮之间才有过渡。
 */
@ObservedV2
class ScriptListItem {
  readonly key: string;
  @Trace script: ConfigScript;

  constructor(script: ConfigScript) {
    this.key = script.id;
    this.script = script;
  }
}

let cachedConfigScripts: ConfigScriptsSnapshot | undefined = undefined;

// 加载、占位和列表三种内容之间淡入淡出，不硬切。
const CONTENT_FADE: TransitionEffect = TransitionEffect.OPACITY.animation({ curve: SETTLE_SPRING });

@ComponentV2
export struct ScriptsPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param foreground: boolean = true;
  @Param reduceMotion: boolean = true;
  @Event onEdit: (id: string) => void = (_id: string): void => {};
  @Local private snapshot: ConfigScriptsSnapshot = cachedConfigScripts ?? emptyConfigScripts();
  @Local private loading: boolean = cachedConfigScripts === undefined;
  @Local private loadFailed: boolean = false;
  @Local private busy: boolean = false;
  @Local private sorting: boolean = false;
  // 正在同步的脚本；从链接或文件导入新脚本时为空。
  @Local private activeScript: string = '';
  @Local private now: number = Date.now();
  @Local private count: number = 0;
  @Local private firstId: string = '';
  @Local private lastId: string = '';
  @Local private urlShown: boolean = false;
  @Local private urlDraft?: ScriptUrlDraft;
  @Local private urlScript?: ConfigScript;
  @Local private urlIssue: ResourceStr = '';
  @Local private discardRequested: boolean = false;
  @Local private deleteShown: boolean = false;
  @Local private toDelete?: ConfigScript;
  @Local private affected: string = '';
  private rows: KeyedListSource<ScriptListItem> = new KeyedListSource<ScriptListItem>();
  private readonly sortSwap: ReplaceSymbolEffect = new ReplaceSymbolEffect(EffectScope.WHOLE);
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

  /** 页面在前台且没开减弱动态时，列表增删和区块切换才带动画。 */
  private animated(): boolean {
    return this.shown && this.foreground && !this.reduceMotion;
  }

  private settle(apply: () => void): void {
    if (this.reduceMotion) {
      apply();
    } else {
      this.getUIContext().animateTo({ curve: SETTLE_SPRING }, apply);
    }
  }

  private accept(store: ConfigScriptsSnapshot, animate: boolean = false): void {
    this.readId++;
    cachedConfigScripts = store;
    this.snapshot = store;
    const previous = new Map<string, ScriptListItem>();
    for (const row of this.rows.values()) { previous.set(row.key, row); }
    const rows = store.scripts.map((script: ConfigScript): ScriptListItem => {
      const row = previous.get(script.id);
      if (row === undefined) { return new ScriptListItem(script); }
      row.script = script;
      return row;
    });
    this.count = rows.length;
    this.firstId = rows[0]?.key ?? '';
    this.lastId = rows[rows.length - 1]?.key ?? '';
    if (rows.length < 2) { this.sorting = false; }
    this.rows.replace(rows, animate && this.animated() ?
      (apply: () => void): void => this.getUIContext().animateTo({ curve: SETTLE_SPRING }, apply) : undefined);
    this.now = Date.now();
  }

  private async refresh(): Promise<void> {
    const read = ++this.readId;
    const silent = cachedConfigScripts !== undefined;
    this.loadFailed = false;
    try {
      const store = await readConfigScripts(this.context.filesDir);
      if (read === this.readId) { this.accept(store, true); }
    } catch (error) {
      if (read === this.readId && !silent) { this.loadFailed = true; }
    } finally { this.loading = false; }
  }

  private retry(): void {
    this.loading = true;
    this.refresh();
  }

  @Monitor('foreground')
  foregroundChanged(): void { if (this.shown && this.foreground) { this.refresh(); } }

  private createScript(): void {
    if (!this.busy && !this.sorting) { this.onEdit(''); }
  }

  private async importFile(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      const uri = await pickDocumentFile(this.context);
      if (uri === undefined) { return; }
      const source = await readScriptText(uri);
      this.accept(await saveConfigScript(this.context.filesDir, undefined, documentFileName(uri), source, '', true), true);
      this.toast($r('app.string.script_saved'));
    } catch (error) { this.toast(configScriptError(error as Object)); }
    finally { this.busy = false; }
  }

  private openUrl(item?: ConfigScript): void {
    if (this.busy) { return; }
    // 打开时取一次快照；抽屉是模态的，开着时只会被它自己的同步改动。
    this.urlScript = item;
    this.urlDraft = new ScriptUrlDraft(item?.url ?? '');
    this.urlIssue = '';
    this.discardRequested = false;
    this.urlShown = true;
  }

  private requestCloseUrl(dismiss: () => void): void {
    if (this.busy) { return; }
    if (this.urlDraft?.dirty() === true) {
      this.settle((): void => { this.discardRequested = true; });
    } else {
      dismiss();
    }
  }

  private async sync(url: string, item?: ConfigScript): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.activeScript = item?.id ?? '';
    this.urlIssue = '';
    try {
      const store = await fetchConfigScript(this.context, url.trim(), item);
      this.accept(store, true);
      this.urlShown = false;
      if (item !== undefined) {
        try {
          const applied = await applyConfigScript(this.context.filesDir, store, '', item.id);
          this.toast(applied ? $r('app.string.script_applied') : $r('app.string.script_synced'));
        } catch (error) { this.toast($r('app.string.script_saved_apply_error', configScriptError(error as Object))); }
      } else { this.toast($r('app.string.script_saved')); }
    } catch (error) {
      if (this.urlShown) { this.urlIssue = configScriptError(error as Object); }
      else { this.toast(configScriptError(error as Object)); }
    } finally { this.busy = false; this.activeScript = ''; }
  }

  private async openDelete(item: ConfigScript): Promise<void> {
    if (this.busy) { return; }
    try {
      // 打开时取一次快照：哪些配置还在用这个脚本。
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
      this.accept(await removeConfigScript(this.context.filesDir, item), true);
      this.deleteShown = false;
      this.toast($r('app.string.script_deleted'));
    } catch (error) { this.toast(configScriptError(error as Object)); }
    finally { this.busy = false; }
  }

  private async move(from: number, to: number): Promise<void> {
    const scripts = this.snapshot.scripts;
    if (this.busy || from === to || scripts[from] === undefined || scripts[to] === undefined) { return; }
    // List 已经把行挪到位：只同步数据，首末行的圆角和分隔线跟着新顺序走。
    this.rows.moveQuietly(from, to);
    const order = this.rows.values();
    this.firstId = order[0]?.key ?? '';
    this.lastId = order[order.length - 1]?.key ?? '';
    this.busy = true;
    try { this.accept(await reorderConfigScripts(this.context.filesDir, scripts[from], scripts[to]), true); }
    catch (error) {
      // 没存上就按原顺序挪回去。
      this.accept(this.snapshot, true);
      this.toast(configScriptError(error as Object));
    }
    finally { this.busy = false; }
  }

  private handleBack(): boolean {
    if (this.sorting) {
      this.settle((): void => { this.sorting = false; });
      return true;
    }
    return false;
  }

  @Builder
  HeaderTitle() { DestinationTitle({ titleText: $r('app.string.script_title') }) }

  @Builder
  AddMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.script_new'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_and_pencil')) })
        .onClick((): void => this.createScript())
      MenuItem({ content: $r('app.string.script_import_url'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.link')) })
        .onClick((): void => this.openUrl())
      MenuItem({ content: $r('app.string.script_import_file'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.folder')) })
        .onClick((): void => { this.importFile(); })
    }
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      if (this.count > 1) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(this.sorting ? $r('sys.symbol.checkmark') : $r('sys.symbol.sort'))
            .fontSize(HEADER_ICON_SIZE)
            .fontColor([$r('sys.color.font_primary')])
            .symbolEffect(this.sortSwap, this.reduceMotion ? 0 : (this.sorting ? 1 : 2))
        }
        .attributeModifier(HEADER_ACTION)
        .systemMaterial(this.appStyle.headerMaterial())
        .accessibilityText($r('app.string.profile_sort'))
        .enabled(!this.busy)
        .onClick((): void => this.settle((): void => { this.sorting = !this.sorting; }))
      }
      Button({ type: ButtonType.Circle }) {
        if (this.busy && this.activeScript === '') {
          LoadingProgress().width(20).height(20).color(this.appStyle.palette.brand)
        } else {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
        }
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($r('app.string.action_add'))
      .enabled(!this.busy && !this.loading && !this.loadFailed && !this.sorting)
      .bindMenu(this.AddMenu)
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ right: PAGE_GUTTER })
  }

  @Builder
  ScriptList() {
    List() {
      LazyForEach(this.rows, (row: ScriptListItem) => {
        ListItem() {
          ScriptRow({
            item: row.script, first: row.key === this.firstId, last: row.key === this.lastId,
            sorting: this.sorting, updating: this.activeScript === row.key, now: this.now,
            motion: !this.reduceMotion,
            onEdit: (): void => { if (!this.busy && !this.sorting) { this.onEdit(row.key); } },
            onUrl: (): void => { if (!this.sorting) { this.openUrl(row.script); } },
            onSync: (): void => { if (!this.sorting) { this.sync(row.script.url, row.script); } },
            onDelete: (): void => { if (!this.sorting) { this.openDelete(row.script); } }
          })
        }
      }, (row: ScriptListItem): string => row.key)
        .onMove(this.sorting && !this.busy ? (from: number, to: number): void => { this.move(from, to); } : undefined)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .cachedCount(2, true)
    .clipContent(ContentClipMode.SAFE_AREA)
    .contentStartOffset(12)
    .contentEndOffset(24)
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }

  @Builder
  Content() {
    if (this.loading) {
      Column() {
        LoadingProgress().width(32).height(32).color(this.appStyle.palette.brand)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .transition(this.reduceMotion ? TransitionEffect.IDENTITY : CONTENT_FADE)
    } else if (this.loadFailed) {
      // 读取失败和空列表分成两支：重试后变成空列表时占位重新入场，插画从头展开。
      Column() {
        ScriptsEmpty({ kind: 'failed', motion: !this.reduceMotion && this.foreground, available: !this.busy,
          onRetry: (): void => this.retry() })
      }
      .width('100%')
      .height('100%')
      .transition(this.reduceMotion ? TransitionEffect.IDENTITY : CONTENT_FADE)
    } else if (this.count === 0) {
      Column() {
        ScriptsEmpty({ kind: 'empty', motion: !this.reduceMotion && this.foreground, available: !this.busy,
          onCreate: (): void => this.createScript(), onImportUrl: (): void => this.openUrl(),
          onImportFile: (): void => { this.importFile(); } })
      }
      .width('100%')
      .height('100%')
      .transition(this.reduceMotion ? TransitionEffect.IDENTITY : CONTENT_FADE)
    } else {
      Column() { this.ScriptList() }
        .width('100%')
        .height('100%')
        .transition(this.reduceMotion ? TransitionEffect.IDENTITY : CONTENT_FADE)
    }
  }

  @Builder
  UrlSheet() {
    if (this.urlDraft !== undefined) {
      ScriptUrlSheet({
        draft: this.urlDraft, scriptName: this.urlScript?.name ?? '', busy: this.busy, issue: this.urlIssue,
        discardRequested: this.discardRequested, motion: !this.reduceMotion,
        onSubmit: (): void => { this.sync(this.urlDraft?.text ?? '', this.urlScript); },
        onClose: (): void => this.requestCloseUrl((): void => { this.urlShown = false; }),
        onResume: (): void => this.settle((): void => { this.discardRequested = false; }),
        onDiscard: (): void => { this.urlShown = false; },
        onChange: (): void => { this.urlIssue = ''; }
      })
    }
  }

  @Builder
  DeleteSheet() {
    if (this.toDelete !== undefined) {
      ScriptDeleteSheet({
        name: this.toDelete.name, url: this.toDelete.url, affected: this.affected, busy: this.busy,
        motion: !this.reduceMotion,
        onConfirm: (): void => { this.remove(); },
        onCancel: (): void => { if (!this.busy) { this.deleteShown = false; } }
      })
    }
  }

  build() {
    ScrollDestination({
      heading: (): void => this.HeaderTitle(),
      actions: (): void => this.HeaderMenus(),
      pageShown: (): void => { this.shown = true; this.refresh(); },
      pageHidden: (): void => { this.shown = false; },
      handleBack: (): boolean => this.handleBack()
    }) {
      Stack() {
        this.Content()
        Column()
          // 两个抽屉的标题区由内容自己绘制，不用系统标题和关闭按钮，高度跟随内容。
          .bindSheet($$this.urlShown, this.UrlSheet, {
            height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM,
            // 键盘弹起时整个抽屉抬到键盘上方并压缩高度，主按钮滚动可达，不被键盘挡住。
            keyboardAvoidMode: SheetKeyboardAvoidMode.TRANSLATE_AND_RESIZE,
            systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
            onWillDismiss: (action: DismissSheetAction): void => this.requestCloseUrl((): void => action.dismiss())
          })
        Column()
          .bindSheet($$this.deleteShown, this.DeleteSheet, {
            height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM,
            systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
            onWillDismiss: (action: DismissSheetAction): void => { if (!this.busy) { action.dismiss(); } }
          })
      }
      .width('100%').height('100%')
    }
  }
}
