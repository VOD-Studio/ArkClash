import { common } from '@kit.AbilityKit';
import { applyConfigScript } from '../../shared/profiles/ScriptApply';
import { profileAddedRules, readAddedRules } from '../../client/AddedRules';
import { getRuntimeStatus } from '../../client/Controller';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ListSource } from '../../components/ListSource';
import { ListRow } from '../../components/ListRow';
import { CARD_RADIUS, PAGE_GUTTER } from '../../components/Theme';
import { ConfigScript, ConfigScriptBinding, ConfigScriptsSnapshot, emptyConfigScripts, ExtensionMode,
  readConfigScripts, saveScriptBinding, scriptBinding, scriptIdentity } from '../../shared/profiles/Scripts';
import { configScriptError } from './ScriptMessages';

@ReusableV2
@ComponentV2
struct ExtensionScriptOption {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require label: ResourceStr;
  @Param subtitle: ResourceStr = '';
  @Param picked: boolean = false;
  @Param active: boolean = true;
  @Event onPick: () => void = (): void => {};

  build() {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.NORMAL, stateEffect: true }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.label).fontFamily(this.appStyle.fontFamily).fontSize(16).fontColor($r('sys.color.font_primary'))
            .width('100%')
          if (this.subtitle !== '') {
            Text(this.subtitle).fontFamily(this.appStyle.fontFamily).fontSize(13)
              .fontColor($r('sys.color.font_secondary')).width('100%')
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.picked) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill')).fontSize(22).fontColor([this.appStyle.palette.brand])
        }
      }.width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
    }.width('100%').constraintSize({ minHeight: 54 }).borderRadius(0).enabled(this.active)
      .backgroundColor(this.picked ? this.appStyle.palette.selectionTonal : this.appStyle.palette.cardBackground)
      .accessibilitySelected(this.picked).onClick((): void => this.onPick())
  }
}

@ComponentV2
export struct ProfileExtensionPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require profileId: string;
  @Param currentProfile: string = '';
  @Param foreground: boolean = true;
  @Event onScripts: () => void = (): void => {};
  @Event onStandardRules: () => void = (): void => {};
  @Local private snapshot: ConfigScriptsSnapshot = emptyConfigScripts();
  @Local private binding: ConfigScriptBinding = { profile: '', mode: 'standard', scriptId: '' };
  @Local private loading: boolean = true;
  @Local private loadFailed: boolean = false;
  @Local private saving: boolean = false;
  @Local private applying: boolean = false;
  @Local private appliedIdentity: string = '';
  @Local private appliedStandard: string = '';
  @Local private standardRevision: string = '';
  @Local private runtimeKnown: boolean = false;
  @Local private changed: boolean = false;
  private scripts: ListSource<ConfigScript> = new ListSource<ConfigScript>();
  private shown: boolean = false;
  private readId: number = 0;
  private openedStandardRules: boolean = false;
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToDisappear(): void {
    ++this.readId;
    if ((this.pending() || this.openedStandardRules) && !this.applying && this.currentProfile === this.profileId) {
      this.apply(true);
    }
  }

  private pending(): boolean {
    return !this.loading && !this.loadFailed && this.currentProfile === this.profileId &&
      (this.runtimeKnown || this.changed) && (this.appliedIdentity !== scriptIdentity(this.snapshot, this.profileId) ||
        this.standardRevision !== this.appliedStandard);
  }

  private missing(): boolean { return scriptIdentity(this.snapshot, this.profileId) === undefined; }

  private accept(store: ConfigScriptsSnapshot): void {
    this.snapshot = store;
    this.binding = scriptBinding(store, this.profileId);
    this.scripts.replace(store.scripts);
  }

  private async refresh(): Promise<void> {
    const read = ++this.readId;
    try {
      const store = await readConfigScripts(this.context.filesDir);
      const rules = await readAddedRules(this.context.filesDir);
      if (read !== this.readId) { return; }
      this.accept(store);
      this.standardRevision = profileAddedRules(rules, this.profileId).revision;
      this.loadFailed = false;
    } catch (error) { if (read === this.readId) { this.loadFailed = true; } }
    finally { if (read === this.readId) { this.loading = false; } }
    try {
      const status = await getRuntimeStatus(this.context.filesDir);
      if (read === this.readId && !this.applying) {
        this.runtimeKnown = status.running;
        this.appliedIdentity = status.profile === this.profileId ? status.profileExtension ?? '' : 'inactive';
        this.appliedStandard = status.profile === this.profileId ? status.standardRulesRevision ?? '' : '';
      }
    } catch (error) { if (read === this.readId) { this.runtimeKnown = false; } }
  }

  @Monitor('foreground')
  foregroundChanged(): void { if (this.shown && this.foreground && !this.saving) { this.refresh(); } }

  private async select(mode: ExtensionMode, id: string): Promise<void> {
    if (this.saving || this.applying || (mode === this.binding.mode && id === this.binding.scriptId)) { return; }
    this.saving = true;
    ++this.readId;
    try {
      const next: ConfigScriptBinding = { profile: this.profileId, mode: mode, scriptId: id };
      this.accept(await saveScriptBinding(this.context.filesDir, this.binding, next));
      this.changed = true;
    } catch (error) {
      if (this.shown && this.foreground) {
        this.getUIContext().getPromptAction().showToast({ message: configScriptError(error as Object) });
      }
      this.refresh();
    } finally { this.saving = false; }
  }

  private async apply(leaving: boolean): Promise<void> {
    if (this.applying || this.saving || (!leaving && (!this.pending() || this.missing()))) { return; }
    this.applying = true;
    const prompt = this.getUIContext().getPromptAction();
    const id = this.profileId;
    let message: ResourceStr = '';
    try {
      const filesDir = this.context.filesDir;
      const store = leaving ? await readConfigScripts(filesDir) : this.snapshot;
      const revision = leaving ? profileAddedRules(await readAddedRules(filesDir), id).revision : this.standardRevision;
      if (await applyConfigScript(filesDir, store, id, '', revision)) {
        this.appliedIdentity = scriptIdentity(store, id) ?? '';
        this.appliedStandard = revision;
        this.changed = false;
        this.openedStandardRules = false;
        if (!leaving) { message = $r('app.string.script_applied'); }
      } else if (!leaving) { message = $r('app.string.script_pending_core'); }
    } catch (error) { message = $r('app.string.script_saved_apply_error', configScriptError(error as Object)); }
    finally {
      this.applying = false;
      if (message !== '' && this.foreground && (leaving || this.shown)) { prompt.showToast({ message: message }); }
    }
  }

  @Builder
  HeaderTitle() { DestinationTitle({ titleText: $r('app.string.profile_extension') }) }

  @Builder
  HeaderMenus() {
    Row() {
      if (this.pending() || this.applying) {
        Button($r('app.string.script_apply_now')).height(36).enabled(!this.applying && !this.saving && !this.missing())
          .onClick((): void => { this.apply(false); })
      }
    }.height('100%').padding({ right: PAGE_GUTTER })
  }

  @Builder
  Heading(title: ResourceStr) {
    Text(title).fontFamily(this.appStyle.fontFamily).fontSize(13).fontWeight(500).fontColor($r('sys.color.font_secondary'))
      .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })
  }

  @Builder
  Footer() {
    Column() {
      ListRow({ title: $r('app.string.script_go_to_manage'), onTap: (): void => this.onScripts() })
      Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
      ListRow({ title: $r('app.string.standard_rules_title'), onTap: (): void => {
        this.openedStandardRules = true;
        this.onStandardRules();
      } })
    }.width('100%').backgroundColor(this.appStyle.palette.cardBackground).borderRadius(CARD_RADIUS)
      .clip(true).enabled(!this.saving && !this.applying).margin({ top: 16 })
  }

  build() {
    NavDestination() {
      Column() {
        if (this.loading) {
          LoadingProgress().width(28).height(28).margin({ top: 20 })
        } else if (this.loadFailed) {
          Text($r('app.string.script_err_store')).margin(16)
          Button($r('app.string.action_retry')).onClick((): void => { this.refresh(); })
        } else {
          List() {
            ListItem() { this.Heading($r('app.string.script_extend_script')) }
            ListItem() {
              ExtensionScriptOption({ label: $r('app.string.script_none'),
                picked: this.binding.mode === 'standard' || this.binding.scriptId === '',
                active: !this.saving && !this.applying,
                onPick: (): void => { this.select('standard', ''); } })
            }.borderRadius(8).clip(true)
            if (this.missing()) {
              ListItem() {
                ExtensionScriptOption({ label: $r('app.string.script_err_missing'),
                  subtitle: $r('app.string.script_clear_missing'), active: !this.saving && !this.applying,
                  onPick: (): void => { this.select('standard', ''); } })
              }.borderRadius(8).clip(true)
            }
            LazyForEach(this.scripts, (item: ConfigScript) => {
              ListItem() {
                ExtensionScriptOption({ label: item.name,
                  picked: this.binding.mode === 'script' && this.binding.scriptId === item.id,
                  active: !this.saving && !this.applying,
                  onPick: (): void => { this.select('script', item.id); } })
              }.borderRadius(8).clip(true)
            }, (item: ConfigScript): string => item.id)
            ListItem() { this.Footer() }
          }.width('100%').layoutWeight(1).padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
            .contentEndOffset(24).cachedCount(2).scrollBar(BarState.Off)
        }
      }.width('100%').height('100%')
    }.title(this.HeaderTitle, { systemMaterial: this.appStyle.regularMaterial() }).menus(this.HeaderMenus)
      .backgroundColor(this.appStyle.palette.pageBackground)
      .onBackPressed((): boolean => this.saving || this.applying)
      .onShown((): void => { this.shown = true; this.refresh(); })
      .onHidden((): void => { this.shown = false; })
  }
}
