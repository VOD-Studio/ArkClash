import { common } from '@kit.AbilityKit';
import { connection } from '../../client/Connection';
import { fetchProfilePreview, isPreviewHostUnavailable, ProfilePreviewGuard, RuntimeProfilePreview }
  from '../../client/ProfilePreview';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { configScriptError } from './ScriptMessages';
import { YamlCodeEditor, YamlCodeEditorController } from './YamlCodeEditor';

@ComponentV2
export struct ProfileRuntimePreviewPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require profileId: string;
  @Param profileName: string = '';
  @Param foreground: boolean = true;
  @Local private loading: boolean = true;
  @Local private startingCore: boolean = false;
  @Local private hostUnavailable: boolean = false;
  @Local private failureText: ResourceStr = '';
  @Local private preview: RuntimeProfilePreview | undefined = undefined;
  private mounted: boolean = false;
  private shown: boolean = false;
  private guard: ProfilePreviewGuard = new ProfilePreviewGuard();
  private editorController: YamlCodeEditorController = new YamlCodeEditorController();
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.mounted = true;
    this.load();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.shown = false;
    this.guard.cancel();
  }

  @Monitor('profileId')
  onProfileChanged(): void {
    if (!this.mounted) { return; }
    this.preview = undefined;
    this.load();
  }

  private async load(): Promise<void> {
    const target = this.profileId;
    const token = this.guard.begin(target);
    this.loading = true;
    this.hostUnavailable = false;
    this.failureText = '';
    try {
      const result = await fetchProfilePreview(this.context.filesDir, target);
      if (!this.mounted || !this.guard.accepts(token, target)) { return; }
      const hadPreview = this.preview !== undefined;
      this.preview = result;
      if (hadPreview) {
        await this.editorController.reloadText(result.yaml);
      }
    } catch (error) {
      if (!this.mounted || !this.guard.accepts(token, target)) { return; }
      this.preview = undefined;
      if (isPreviewHostUnavailable(error as Object)) {
        this.hostUnavailable = true;
      } else {
        this.failureText = configScriptError(error as Object);
      }
    } finally {
      if (this.mounted && this.guard.accepts(token, target)) {
        this.loading = false;
      }
    }
  }

  private async startCoreAndRetry(): Promise<void> {
    if (this.startingCore || this.loading) { return; }
    const target = this.profileId;
    this.startingCore = true;
    try {
      await connection.ensureReady(this.context);
    } catch (_error) {
      // 若启动失败或被拒绝，下面按最新状态重新提示原因。
    } finally {
      if (this.mounted) { this.startingCore = false; }
    }
    if (this.mounted && target === this.profileId) {
      await this.load();
    }
  }

  private versionSummary(item: RuntimeProfilePreview): ResourceStr {
    const rawSaved = item.contentRevision !== '' ? item.contentRevision : item.contentHash;
    const saved = rawSaved.length > 12 ? rawSaved.substring(0, 12) : rawSaved;
    if (item.applied) {
      return saved !== '' ?
        $r('app.string.profile_preview_version_applied', String(item.configRevision), saved) :
        $r('app.string.profile_preview_version_applied_only', String(item.configRevision));
    }
    return saved !== '' ?
      $r('app.string.profile_preview_version_saved', saved) :
      $r('app.string.profile_preview_version_unsaved');
  }

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: this.profileName !== '' ? this.profileName : $r('app.string.profile_runtime_preview') })
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
      }.attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial())
        .accessibilityText($r('app.string.action_retry'))
        .enabled(!this.loading && !this.startingCore)
        .onClick((): void => { this.load(); })
    }.height('100%').padding({ right: PAGE_GUTTER })
  }

  build() {
    NavDestination() {
      Column() {
        if (this.loading || this.startingCore) {
          Column({ space: 12 }) {
            LoadingProgress().width(32).height(32).color(this.appStyle.palette.brand)
            Text($r('app.string.profile_preview_loading')).fontFamily(this.appStyle.fontFamily)
              .fontSize(14).fontColor($r('sys.color.font_secondary'))
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.hostUnavailable) {
          Column({ space: 16 }) {
            Text($r('app.string.profile_preview_host_unavailable')).fontFamily(this.appStyle.fontFamily)
              .fontSize(15).lineHeight(22).fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center)
            Row({ space: 12 }) {
              Button($r('app.string.profile_preview_start_core')).height(44)
                .onClick((): void => { this.startCoreAndRetry(); })
              Button($r('app.string.action_retry'), { buttonStyle: ButtonStyleMode.NORMAL }).height(44)
                .onClick((): void => { this.load(); })
            }
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(PAGE_GUTTER)
        } else if (this.failureText !== '') {
          Column({ space: 16 }) {
            Text(this.failureText).fontFamily(this.appStyle.fontFamily)
              .fontSize(15).lineHeight(22).fontColor($r('app.color.status_error')).textAlign(TextAlign.Center)
            Button($r('app.string.action_retry')).height(44).onClick((): void => { this.load(); })
          }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(PAGE_GUTTER)
        } else if (this.preview !== undefined) {
          Column({ space: 6 }) {
            Text(this.versionSummary(this.preview)).fontFamily(this.appStyle.fontFamily)
              .fontSize(13).lineHeight(18).fontColor($r('sys.color.font_secondary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
            if (!this.preview.applied) {
              Text($r('app.string.profile_preview_not_applied')).fontFamily(this.appStyle.fontFamily)
                .fontSize(13).lineHeight(18).fontColor($r('app.color.warning')).width('100%')
            }
          }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 4 })
          YamlCodeEditor({
            initialText: this.preview.yaml,
            readOnly: true,
            editorEnabled: true,
            foreground: this.foreground && this.shown,
            controller: this.editorController
          })
        }
      }.width('100%').height('100%')
    }.title(this.HeaderTitle, { systemMaterial: this.appStyle.regularMaterial() }).menus(this.HeaderMenus)
      .backgroundColor(this.appStyle.palette.pageBackground)
      .onShown((): void => { this.shown = true; })
      .onHidden((): void => { this.shown = false; })
  }
}
