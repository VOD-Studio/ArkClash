import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { webview } from '@kit.ArkWeb';
import { appearanceHex } from '../../components/AppearancePalette';
import { ScrollControls } from '../../components/ScrollControls';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { EditorViewport } from './EditorViewport';

const YAML_EDITOR_TEXT_PREFIX = 'arkclash-yaml:';
const YAML_TRANSFER_CHUNK = 131072;

interface YamlEditorAppearance {
  dark: boolean;
  surface: string;
  accent: string;
  font: number;
  wrap: boolean;
  chinese: boolean;
  language: string;
  readOnly: boolean;
}

interface YamlEditorToolbarAction {
  icon: Resource;
  label: Resource;
  available: boolean;
  invoke: () => void;
}

class YamlEditorStatusBridge {
  private notify: (dirty: boolean, undo: boolean, redo: boolean) => void;

  constructor(notify: (dirty: boolean, undo: boolean, redo: boolean) => void) { this.notify = notify; }
  changed(dirty: boolean, undo: boolean, redo: boolean): void { this.notify(dirty, undo, redo); }
}

interface YamlCodeEditorHost {
  readText: () => Promise<string>;
  replaceText: (text: string) => Promise<boolean>;
  reloadText: (text: string) => Promise<boolean>;
}

/** 供父容器按需读取、替换或重载 YAML 编辑器内容，避免大文本同步回调阻塞主线程。 */
export class YamlCodeEditorController {
  private host: YamlCodeEditorHost | undefined = undefined;
  private fallbackText: string = '';

  attach(host: YamlCodeEditorHost | undefined, initial: string): void {
    this.host = host;
    this.fallbackText = initial;
  }

  setFallback(text: string): void {
    this.fallbackText = text;
  }

  async readText(): Promise<string> {
    if (this.host === undefined) { return this.fallbackText; }
    return await this.host.readText();
  }

  async replaceText(text: string): Promise<boolean> {
    this.fallbackText = text;
    if (this.host === undefined) { return false; }
    return await this.host.replaceText(text);
  }

  async reloadText(text: string): Promise<boolean> {
    this.fallbackText = text;
    if (this.host === undefined) { return false; }
    return await this.host.reloadText(text);
  }
}

@ComponentV2
export struct YamlCodeEditor {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param initialText: string = '';
  @Param readOnly: boolean = false;
  @Param editorEnabled: boolean = true;
  @Param foreground: boolean = true;
  @Param controller: YamlCodeEditorController | undefined = undefined;
  @Event onDirtyChange: (dirty: boolean) => void = (_dirty: boolean): void => {};
  @Event onReadyChange: (ready: boolean) => void = (_ready: boolean): void => {};
  @Local private ready: boolean = false;
  @Local private loadFailed: boolean = false;
  @Local private undoEnabled: boolean = false;
  @Local private redoEnabled: boolean = false;
  @Local private fontIndex: number = 0;
  @Local private wrapLines: boolean = false;
  private fontSizes: number[] = [14, 17, 20];
  private mounted: boolean = false;
  private webGeneration: number = 0;
  private webStarted: boolean = false;
  private pendingText: string = '';
  private settings: preferences.Preferences | undefined = undefined;
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private web: webview.WebviewController = new webview.WebviewController();
  private bridge: YamlEditorStatusBridge = new YamlEditorStatusBridge((dirty: boolean, undo: boolean, redo: boolean) => {
    if (!this.mounted) { return; }
    this.undoEnabled = undo;
    this.redoEnabled = redo;
    this.onDirtyChange(dirty);
  });

  aboutToAppear(): void {
    this.mounted = true;
    this.pendingText = this.initialText;
    this.attachController();
    this.loadPreferences();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    ++this.webGeneration;
    this.controller?.attach(undefined, this.pendingText);
  }

  private attachController(): void {
    const host: YamlCodeEditorHost = {
      readText: (): Promise<string> => this.readDocument(),
      replaceText: (text: string): Promise<boolean> => this.replaceDocument(text),
      reloadText: (text: string): Promise<boolean> => this.reloadDocument(text)
    };
    this.controller?.attach(host, this.pendingText);
  }

  private async loadPreferences(): Promise<void> {
    try {
      this.settings = await preferences.getPreferences(this.context, { name: 'script-editor' });
      const index = await this.settings.get('font', 0) as number;
      const wrap = await this.settings.get('wrap', false) as boolean;
      if (!this.mounted) { return; }
      this.fontIndex = this.fontSizes[index] === undefined ? 0 : index;
      this.wrapLines = wrap;
      this.updateAppearance();
    } catch (_error) {
      this.settings = undefined;
    }
  }

  private editorAppearance(): YamlEditorAppearance {
    return {
      dark: this.appStyle.dark,
      surface: appearanceHex(this.appStyle.palette.pageBackground),
      accent: appearanceHex(this.appStyle.palette.brand),
      font: this.fontSizes[this.fontIndex],
      wrap: this.wrapLines,
      chinese: i18n.System.getSystemLanguage().startsWith('zh'),
      language: 'yaml',
      readOnly: this.readOnly
    };
  }

  private async openInWeb(text: string, generation: number): Promise<boolean> {
    await this.web.runJavaScriptExt(`window.arkScriptEditor.beginOpen(${JSON.stringify(this.editorAppearance())})`);
    for (let offset = 0; offset < text.length; offset += YAML_TRANSFER_CHUNK) {
      if (!this.mounted || generation !== this.webGeneration) { return false; }
      const chunk = text.substring(offset, Math.min(text.length, offset + YAML_TRANSFER_CHUNK));
      await this.web.runJavaScriptExt(`window.arkScriptEditor.appendChunk(${JSON.stringify(chunk)})`);
    }
    if (!this.mounted || generation !== this.webGeneration) { return false; }
    const result = await this.web.runJavaScriptExt('window.arkScriptEditor.finishOpen()');
    return result.getBoolean();
  }

  private async startEditor(): Promise<void> {
    if (!this.mounted || this.webStarted) { return; }
    this.webStarted = true;
    const generation = ++this.webGeneration;
    try {
      const opened = await this.openInWeb(this.pendingText, generation);
      if (this.mounted && generation === this.webGeneration) {
        this.ready = opened;
        this.onReadyChange(opened);
      }
    } catch (_error) {
      if (this.mounted && generation === this.webGeneration) {
        this.loadFailed = true;
        this.onReadyChange(false);
      }
    }
  }

  private async reloadDocument(text: string): Promise<boolean> {
    this.pendingText = text;
    if (!this.mounted || !this.ready) { return false; }
    const generation = ++this.webGeneration;
    try {
      const opened = await this.openInWeb(text, generation);
      if (this.mounted && generation === this.webGeneration) {
        this.undoEnabled = false;
        this.redoEnabled = false;
        this.onDirtyChange(false);
      }
      return opened;
    } catch (_error) {
      return false;
    }
  }

  private async replaceDocument(text: string): Promise<boolean> {
    this.pendingText = text;
    if (!this.mounted || !this.ready || this.readOnly) { return false; }
    const generation = this.webGeneration;
    try {
      await this.web.runJavaScriptExt('window.arkScriptEditor.beginReplace()');
      for (let offset = 0; offset < text.length; offset += YAML_TRANSFER_CHUNK) {
        if (!this.mounted || generation !== this.webGeneration) { return false; }
        const chunk = text.substring(offset, Math.min(text.length, offset + YAML_TRANSFER_CHUNK));
        await this.web.runJavaScriptExt(`window.arkScriptEditor.appendReplaceChunk(${JSON.stringify(chunk)})`);
      }
      if (!this.mounted || generation !== this.webGeneration) { return false; }
      const result = await this.web.runJavaScriptExt('window.arkScriptEditor.finishReplace()');
      return result.getBoolean();
    } catch (_error) {
      return false;
    }
  }

  private unwrapEditorString(wire: string): string {
    const text = wire.startsWith('"') ? JSON.parse(wire) as string : wire;
    if (!text.startsWith(YAML_EDITOR_TEXT_PREFIX)) {
      throw new Error('io');
    }
    return text.substring(YAML_EDITOR_TEXT_PREFIX.length);
  }

  private async readDocument(): Promise<string> {
    if (!this.ready) { return this.pendingText; }
    const lengthResult = await this.web.runJavaScriptExt('window.arkScriptEditor.length()');
    const total = lengthResult.getNumber();
    if (!Number.isFinite(total) || total <= 0) { return ''; }
    const parts: string[] = [];
    for (let offset = 0; offset < total; offset += YAML_TRANSFER_CHUNK) {
      const end = Math.min(total, offset + YAML_TRANSFER_CHUNK);
      const result = await this.web.runJavaScriptExt(
        `"${YAML_EDITOR_TEXT_PREFIX}" + window.arkScriptEditor.slice(${offset}, ${end})`);
      parts.push(this.unwrapEditorString(result.getString()));
    }
    const full = parts.join('');
    this.pendingText = full;
    return full;
  }

  private async readSelection(): Promise<string> {
    const result = await this.web.runJavaScriptExt(
      `"${YAML_EDITOR_TEXT_PREFIX}" + window.arkScriptEditor.selection()`);
    return this.unwrapEditorString(result.getString());
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
    } catch (_error) {
      this.toast($r('app.string.script_err_store'));
    }
  }

  private toast(message: ResourceStr): void {
    if (this.mounted && this.foreground) {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private command(action: 'undo' | 'redo' | 'search' | 'selectAll' | 'complete'): void {
    if (this.ready && this.editorEnabled) {
      this.web.runJavaScript(`window.arkScriptEditor.${action}()`).catch((): void => {});
    }
  }

  private async copyText(all: boolean): Promise<void> {
    if (!this.ready || !this.editorEnabled) { return; }
    try {
      const text = all ? await this.readDocument() : await this.readSelection();
      if (text !== '') {
        await pasteboard.getSystemPasteboard().setData(
          pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
        this.toast($r('app.string.copied'));
      }
    } catch (_error) {
      this.toast($r('app.string.err_io', ''));
    }
  }

  private retryWeb(): void {
    this.webStarted = false;
    this.ready = false;
    this.loadFailed = false;
    this.web = new webview.WebviewController();
  }

  @Builder
  ToolbarAction($$: YamlEditorToolbarAction) {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph($$.icon).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
    }.attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
      .accessibilityText($$.label).enabled($$.available).onClick((): void => $$.invoke())
  }

  @Builder
  EditorMenu() {
    Menu() {
      if (!this.readOnly) {
        MenuItem({ content: $r('app.string.script_complete') }).onClick((): void => this.command('complete'))
      }
      MenuItem({ content: $r('app.string.added_rules_select_all') }).onClick((): void => this.command('selectAll'))
      MenuItem({ content: $r('app.string.script_copy_selection') }).onClick((): void => { this.copyText(false); })
      if (this.readOnly) {
        MenuItem({ content: $r('app.string.yaml_copy_all') }).onClick((): void => { this.copyText(true); })
      }
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
  Toolbar() {
    Row({ space: HEADER_GAP }) {
      if (!this.readOnly) {
        this.ToolbarAction({ icon: $r('sys.symbol.undo'), label: $r('app.string.script_undo'),
          available: this.ready && this.undoEnabled && this.editorEnabled,
          invoke: (): void => this.command('undo') })
        this.ToolbarAction({ icon: $r('sys.symbol.redo'), label: $r('app.string.script_redo'),
          available: this.ready && this.redoEnabled && this.editorEnabled,
          invoke: (): void => this.command('redo') })
        this.ToolbarAction({ icon: $r('sys.symbol.list_bullet'), label: $r('app.string.script_complete'),
          available: this.ready && this.editorEnabled,
          invoke: (): void => this.command('complete') })
      } else {
        this.ToolbarAction({ icon: $r('sys.symbol.rectangle_on_rectangle'), label: $r('app.string.yaml_copy_all'),
          available: this.ready && this.editorEnabled,
          invoke: (): void => { this.copyText(true); } })
      }
      Blank()
      this.ToolbarAction({ icon: $r('sys.symbol.magnifyingglass'), label: $r('app.string.diagnostics_search'),
        available: this.ready && this.editorEnabled, invoke: (): void => this.command('search') })
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
      }.attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
        .accessibilityText($r('app.string.action_more')).enabled(this.ready && this.editorEnabled)
        .bindMenu(this.EditorMenu)
    }.width('100%').height(56).padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
  }

  build() {
    Column() {
      if (!this.loadFailed) {
        ScrollControls({ controls: (): void => this.Toolbar() }) {
          EditorViewport({ controller: this.web, ready: this.ready }) {
            Web({ src: $rawfile('script-editor/index.html'), controller: this.web })
              .width('100%')
              .height('100%')
              .enabled(this.editorEnabled)
              .javaScriptAccess(true)
              .fileAccess(false)
              .domStorageAccess(false)
              .blockNetwork(true)
              .mixedMode(MixedMode.None)
              .javaScriptProxy({ object: this.bridge, name: 'ArkEditorStatus', methodList: ['changed'], controller: this.web })
              .onLoadIntercept((event: OnLoadInterceptEvent): boolean => event.data.isMainFrame() &&
                !event.data.getRequestUrl().endsWith('/script-editor/index.html'))
              .onPageEnd((): void => { this.startEditor(); })
              .onErrorReceive((event: OnErrorReceiveEvent): void => {
                if (event.request.isMainFrame()) {
                  this.loadFailed = true;
                  this.onReadyChange(false);
                }
              })
          }
        }
      } else {
        Column({ space: 12 }) {
          Text($r('app.string.yaml_editor_failed')).fontSize(15).fontColor($r('sys.color.font_secondary'))
          Button($r('app.string.action_retry')).onClick((): void => this.retryWeb())
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(PAGE_GUTTER)
      }
    }.width('100%').layoutWeight(1)
  }
}
