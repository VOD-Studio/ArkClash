import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { webview } from '@kit.ArkWeb';
import { applyConfigScript } from '../../shared/profiles/ScriptApply';
import { appearanceHex } from '../../components/AppearancePalette';
import { ScrollControls } from '../../components/ScrollControls';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ScrollDestination } from '../../components/ScrollDestination';
import { HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { ConfigScript, readConfigScripts, saveConfigScript, SCRIPT_TEMPLATE } from '../../shared/profiles/Scripts';
import { EditorViewport } from './EditorViewport';
import { configScriptError } from './ScriptMessages';

const EDITOR_TEXT_PREFIX = 'arkclash-editor:';

interface ScriptEditorAppearance {
  dark: boolean;
  surface: string;
  accent: string;
  font: number;
  wrap: boolean;
  chinese: boolean;
  topInset: number;
}

interface ScriptEditorAction {
  icon: Resource;
  label: Resource;
  available: boolean;
  invoke: () => void;
}

class ScriptEditorStatusBridge {
  private notify: (dirty: boolean, undo: boolean, redo: boolean) => void;
  private onPainted: () => void;

  constructor(notify: (dirty: boolean, undo: boolean, redo: boolean) => void, onPainted: () => void) {
    this.notify = notify;
    this.onPainted = onPainted;
  }
  changed(dirty: boolean, undo: boolean, redo: boolean): void { this.notify(dirty, undo, redo); }
  painted(): void { this.onPainted(); }
}

@ComponentV2
export struct ScriptEditorPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param scriptId: string = '';
  @Param foreground: boolean = true;
  @Event onClose: () => void = (): void => {};
  @Local private record: ConfigScript | undefined = undefined;
  @Local private scriptName: string = '';
  @Local private draftName: string = '';
  @Local private loaded: boolean = false;
  @Local private ready: boolean = false;
  @Local private webPainted: boolean = false;
  @Local private loadFailed: boolean = false;
  @Local private editorFailed: boolean = false;
  @Local private saving: boolean = false;
  @Local private dirty: boolean = false;
  @Local private undoEnabled: boolean = false;
  @Local private redoEnabled: boolean = false;
  @Local private nameShown: boolean = false;
  @Local private closeShown: boolean = false;
  @Local private failure: ResourceStr = '';
  @Local private fontIndex: number = 0;
  @Local private wrapLines: boolean = false;
  private fontSizes: number[] = [14, 17, 20];
  private initialSource: string = '';
  private viewportInset: number = 0;
  private revealTimer: number = -1;
  private mounted: boolean = false;
  private webGeneration: number = 0;
  private webStarted: boolean = false;
  private saveAfterName: boolean = false;
  private approvedClose: boolean = false;
  private settings: preferences.Preferences | undefined = undefined;
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private web: webview.WebviewController = new webview.WebviewController();
  private bridge: ScriptEditorStatusBridge = new ScriptEditorStatusBridge((dirty: boolean, undo: boolean, redo: boolean) => {
    if (!this.mounted) { return; }
    this.dirty = dirty;
    this.undoEnabled = undo;
    this.redoEnabled = redo;
  }, (): void => {
    if (!this.mounted) { return; }
    this.clearRevealTimer();
    this.webPainted = true;
  });

  aboutToAppear(): void { this.mounted = true; this.load(); }
  aboutToDisappear(): void { this.mounted = false; this.clearRevealTimer(); ++this.webGeneration; }

  private clearRevealTimer(): void {
    if (this.revealTimer !== -1) {
      clearTimeout(this.revealTimer);
      this.revealTimer = -1;
    }
  }

  private async load(): Promise<void> {
    this.loadFailed = false;
    try {
      const store = await readConfigScripts(this.context.filesDir);
      if (!this.mounted) { return; }
      this.record = store.scripts.find((item: ConfigScript): boolean => item.id === this.scriptId);
      if (this.scriptId !== '' && this.record === undefined) { throw new Error('script_missing'); }
      this.initialSource = this.record?.source ?? SCRIPT_TEMPLATE;
      this.scriptName = this.record?.name ?? '';
      try {
        this.settings = await preferences.getPreferences(this.context, { name: 'script-editor' });
        const index = await this.settings.get('font', 0) as number;
        this.fontIndex = this.fontSizes[index] === undefined ? 0 : index;
        this.wrapLines = await this.settings.get('wrap', false) as boolean;
      } catch (error) { this.settings = undefined; }
      if (this.mounted) { this.loaded = true; }
    } catch (error) {
      if (this.mounted) { this.failure = configScriptError(error as Object); this.loadFailed = true; }
    }
  }

  private editorAppearance(): ScriptEditorAppearance {
    return { dark: this.appStyle.isDark, surface: appearanceHex(this.appStyle.palette.pageBackground),
      accent: appearanceHex(this.appStyle.palette.brand), font: this.fontSizes[this.fontIndex], wrap: this.wrapLines,
      chinese: i18n.System.getSystemLanguage().startsWith('zh'), topInset: this.viewportInset };
  }

  private async startEditor(): Promise<void> {
    if (!this.mounted || this.webStarted) { return; }
    this.webStarted = true;
    this.webPainted = false;
    this.clearRevealTimer();
    const generation = ++this.webGeneration;
    try {
      const result = await this.web.runJavaScriptExt(`window.arkScriptEditor.open(${JSON.stringify(this.initialSource)},` +
        `${JSON.stringify(this.editorAppearance())})`);
      if (this.mounted && generation === this.webGeneration) {
        this.ready = result.getBoolean();
        if (this.ready && !this.webPainted) {
          this.revealTimer = setTimeout((): void => {
            this.revealTimer = -1;
            if (this.mounted && generation === this.webGeneration) { this.webPainted = true; }
          }, 350);
        }
      }
    } catch (error) {
      if (this.mounted && generation === this.webGeneration) { this.editorFailed = true; }
    }
  }

  @Monitor('appStyle.palette', 'appStyle.dark', 'fontIndex', 'wrapLines')
  updateAppearance(): void {
    if (this.ready) {
      this.web.runJavaScript(`window.arkScriptEditor.appearance(${JSON.stringify(this.editorAppearance())})`)
        .catch((): void => {});
    }
  }

  private async saveSettings(): Promise<void> {
    try {
      await this.settings?.put('font', this.fontIndex);
      await this.settings?.put('wrap', this.wrapLines);
      await this.settings?.flush();
    } catch (error) { this.toast($r('app.string.script_err_store')); }
  }

  private toast(message: ResourceStr): void {
    if (this.mounted && this.foreground) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }

  private command(action: 'undo' | 'redo' | 'search' | 'selectAll' | 'complete'): void {
    if (this.ready && !this.saving) { this.web.runJavaScript(`window.arkScriptEditor.${action}()`).catch((): void => {}); }
  }

  private async editorText(member: 'source' | 'selection'): Promise<string> {
    const result = await this.web.runJavaScriptExt(`"${EDITOR_TEXT_PREFIX}" + window.arkScriptEditor.${member}()`);
    // ArkWeb 在部分系统版本上用 JSON 字符串返回文本，前缀避免误把正文中的引号当成传输格式。
    const wire = result.getString();
    const text = wire.startsWith('"') ? JSON.parse(wire) as string : wire;
    if (!text.startsWith(EDITOR_TEXT_PREFIX)) { throw new Error('script_store'); }
    return text.substring(EDITOR_TEXT_PREFIX.length);
  }

  private async copySelection(): Promise<void> {
    if (!this.ready || this.saving) { return; }
    try {
      const text = await this.editorText('selection');
      if (text !== '') {
        await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      }
    } catch (error) { this.toast(configScriptError(error as Object)); }
  }

  private editName(saveAfter: boolean): void {
    this.draftName = this.scriptName;
    this.saveAfterName = saveAfter;
    this.nameShown = true;
  }

  private confirmName(): void {
    this.scriptName = this.draftName.trim();
    this.nameShown = false;
  }

  private async save(): Promise<void> {
    if (!this.ready || this.saving) { return; }
    if (this.scriptName.trim() === '') { this.editName(true); return; }
    this.saving = true;
    this.failure = '';
    try {
      const source = await this.editorText('source');
      const store = await saveConfigScript(this.context.filesDir, this.record, this.scriptName, source,
        this.record?.url ?? '');
      let feedback: ResourceStr = $r('app.string.script_saved');
      if (this.record !== undefined) {
        try {
          if (await applyConfigScript(this.context.filesDir, store, '', this.record.id)) {
            feedback = $r('app.string.script_applied');
          }
        } catch (error) {
          feedback = $r('app.string.script_saved_apply_error', configScriptError(error as Object));
        }
      }
      this.toast(feedback);
      this.close();
    } catch (error) {
      this.failure = configScriptError(error as Object);
      this.toast(this.failure);
    } finally { this.saving = false; }
  }

  private hasDraft(): boolean { return this.dirty || this.scriptName !== (this.record?.name ?? ''); }

  private close(): void { this.approvedClose = true; if (this.mounted) { this.onClose(); } }

  private requestBack(): boolean {
    if (this.approvedClose) { return false; }
    if (this.saving) { return true; }
    if (this.hasDraft()) { this.closeShown = true; return true; }
    return false;
  }

  @Builder
  HeaderTitle() {
    if (this.scriptId === '' || this.loaded) {
      DestinationTitle({ titleText: this.scriptName || $r('app.string.script_unnamed'), selectable: true,
        actionGlyph: 'edit', onSelect: (): void => { if (this.ready && !this.saving) { this.editName(false); } } })
    } else {
      DestinationTitle({ titleText: $r('app.string.script_title') })
    }
  }

  @Builder
  Action($$: ScriptEditorAction) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($$.icon).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
    }.attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($$.label).enabled($$.available).onClick((): void => $$.invoke())
  }

  @Builder
  EditorMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.script_complete') }).onClick((): void => this.command('complete'))
      MenuItem({ content: $r('app.string.added_rules_select_all') }).onClick((): void => this.command('selectAll'))
      MenuItem({ content: $r('app.string.script_copy_selection') }).onClick((): void => { this.copySelection(); })
      MenuItem({ content: $r('app.string.script_editor_wrap') }).selected(this.wrapLines).selectIcon(true)
        .onClick((): void => { this.wrapLines = !this.wrapLines; this.saveSettings(); })
      MenuItemGroup({ header: $r('app.string.script_editor_font') }) {
        MenuItem({ content: $r('app.string.script_font_standard') }).selected(this.fontIndex === 0).selectIcon(true)
          .onClick((): void => { this.fontIndex = 0; this.saveSettings(); })
        MenuItem({ content: $r('app.string.script_font_large') }).selected(this.fontIndex === 1).selectIcon(true)
          .onClick((): void => { this.fontIndex = 1; this.saveSettings(); })
        MenuItem({ content: $r('app.string.script_font_extra_large') }).selected(this.fontIndex === 2).selectIcon(true)
          .onClick((): void => { this.fontIndex = 2; this.saveSettings(); })
      }
    }
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      Button($r('app.string.action_save')).height(36).enabled(this.ready && !this.saving &&
        (this.record === undefined || this.hasDraft())).onClick((): void => { this.save(); })
    }.height('100%').padding({ right: PAGE_GUTTER })
  }

  @Builder
  EditorToolbar() {
    Row({ space: HEADER_GAP }) {
      this.Action({ icon: $r('sys.symbol.undo'), label: $r('app.string.script_undo'),
        available: this.ready && this.undoEnabled && !this.saving, invoke: (): void => this.command('undo') })
      this.Action({ icon: $r('sys.symbol.redo'), label: $r('app.string.script_redo'),
        available: this.ready && this.redoEnabled && !this.saving, invoke: (): void => this.command('redo') })
      Blank()
      this.Action({ icon: $r('sys.symbol.magnifyingglass'), label: $r('app.string.diagnostics_search'),
        available: this.ready && !this.saving, invoke: (): void => this.command('search') })
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
      }.attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
        .accessibilityText($r('app.string.action_more')).enabled(this.ready && !this.saving).bindMenu(this.EditorMenu)
    }.width('100%').height(56).padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }

  @Builder
  NameSheet() {
    Column({ space: 16 }) {
      TextInput({ text: this.draftName, placeholder: $r('app.string.script_name_hint') }).maxLength(64)
        .width('100%').onChange((text: string): void => { this.draftName = text; })
      Button($r('app.string.action_save')).width('100%').height(48).enabled(this.draftName.trim() !== '')
        .onClick((): void => this.confirmName())
    }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }

  @Builder
  CloseSheet() {
    Column({ space: 12 }) {
      Button($r('app.string.action_save')).width('100%').height(48).onClick((): void => {
        this.saveAfterName = true;
        this.closeShown = false;
      })
      Button($r('app.string.profile_discard'), { role: ButtonRole.ERROR }).width('100%').height(48)
        .onClick((): void => { this.closeShown = false; this.close(); })
      Button($r('app.string.profile_keep_editing')).width('100%').height(48)
        .onClick((): void => { this.saveAfterName = false; this.closeShown = false; })
    }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }

  @Builder
  EditorControls() {
    this.EditorToolbar()
    if (this.record?.url) {
      Text($r('app.string.script_remote_edit_hint')).fontSize(13).fontColor($r('sys.color.font_secondary'))
        .width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 8 })
    }
    if (this.failure !== '') {
      Text(this.failure).fontSize(13).fontColor($r('app.color.status_error'))
        .width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 8 })
    }
  }

  build() {
    ScrollDestination({
      heading: (): void => this.HeaderTitle(),
      actions: (): void => this.HeaderMenus(),
      handleBack: (): boolean => this.requestBack()
    }) {
      Column() {
        Column() {
          if (!this.editorFailed && !this.loadFailed) {
            ScrollControls({ controls: (): void => this.EditorControls() }) {
              EditorViewport({ controller: this.web, ready: this.ready, painted: this.webPainted,
                onInsetChange: (inset: number): void => { this.viewportInset = inset; } }) {
                if (this.loaded) {
                  Web({ src: $rawfile('script-editor/index.html'), controller: this.web })
                    .width('100%').height('100%').enabled(!this.saving)
                    .backgroundColor(this.appStyle.palette.pageBackground)
                    .darkMode(this.appStyle.isDark ? WebDarkMode.On : WebDarkMode.Off)
                    .javaScriptAccess(true)
                    .fileAccess(false).domStorageAccess(false).blockNetwork(true).mixedMode(MixedMode.None)
                    .javaScriptProxy({ object: this.bridge, name: 'ArkEditorStatus', methodList: ['changed', 'painted'], controller: this.web })
                    .onLoadIntercept((event: OnLoadInterceptEvent): boolean => event.data.isMainFrame() &&
                      !event.data.getRequestUrl().endsWith('/script-editor/index.html'))
                    .onPageEnd((): void => { this.startEditor(); })
                    .onErrorReceive((event: OnErrorReceiveEvent): void => {
                      if (event.request.isMainFrame()) { this.editorFailed = true; }
                    })
                }
              }
            }
          } else {
            Text(this.editorFailed ? $r('app.string.script_editor_failed') : this.failure).margin(16)
            Button($r('app.string.action_retry')).onClick((): void => {
              if (this.editorFailed) {
                this.webStarted = false;
                this.ready = false;
                this.webPainted = false;
                this.clearRevealTimer();
                this.web = new webview.WebviewController();
                this.editorFailed = false;
              } else { this.load(); }
            })
          }
        }.width('100%').height('100%')
        .bindSheet($$this.nameShown, this.NameSheet(), { height: SheetSize.FIT_CONTENT,
          title: { title: $r('app.string.script_name_hint') }, showClose: true, systemMaterial: this.appStyle.sheetMaterial(),
          onWillDismiss: (action: DismissSheetAction): void => { this.saveAfterName = false; action.dismiss(); },
          onDisappear: (): void => {
            if (this.saveAfterName && this.scriptName !== '') { this.saveAfterName = false; this.save(); }
            else { this.saveAfterName = false; }
          } })
      }.width('100%').height('100%')
      .bindSheet($$this.closeShown, this.CloseSheet(), { height: SheetSize.FIT_CONTENT,
        title: { title: $r('app.string.profile_unsaved_title') }, showClose: true, systemMaterial: this.appStyle.sheetMaterial(),
        onDisappear: (): void => { if (this.saveAfterName) { this.saveAfterName = false; this.save(); } } })
    }
  }
}
