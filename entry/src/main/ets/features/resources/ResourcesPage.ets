import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { pickDocumentFile } from '../../client/DocumentPicker';
import { fetchConfigScript } from '../../client/ScriptDownloads';
import { applyConfigScript } from '../../shared/profiles/ScriptApply';
import { ConfigScript, readConfigScripts } from '../../shared/profiles/Scripts';
import { formatUpdatedAgo } from '../../components/Format';
import { connection, Connection } from '../../client/Connection';
import { DestinationTitle } from '../../components/DestinationTitle';
import {
  COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE, HEADER_ACTION, HEADER_GAP, HEADER_ICON_SIZE,
  PAGE_GUTTER
} from '../../components/Theme';
import { GEO_DEFAULT_URLS, GEO_RESOURCE_IDS, GeoResourceId, GeoResourceStatus, GeoUrls } from '../../shared/GeoResources';
import { GeoEditorDraft, GeoResourceEditor, geoErrorText } from './GeoResourceEditor';
import { GeoResourceRow } from './GeoResourceRow';
import { GeoResourceItem, ResourcesStore } from './Resources';
import { RuntimeProviderRow } from './RuntimeProviderRow';
import { providerErrorText, RuntimeProviderRowModel, RuntimeProvidersStore } from './RuntimeProvidersStore';

@ComponentV2
export struct ResourcesPage {
  @Param @Require topInset: number;
  @Event onScript: (id: string) => void = (_id: string): void => {};
  @Local private remoteScripts: ConfigScript[] = [];
  @Local private syncingScript: string = '';
  @Local private appStyle: AppearanceState = appAppearance;
  @Param foreground: boolean = true;
  @Local store: ResourcesStore = new ResourcesStore();
  @Local providers: RuntimeProvidersStore = new RuntimeProvidersStore();
  @Local conn: Connection = connection;
  @Local shown: boolean = false;
  @Local editing: boolean = false;
  @Local draft: GeoEditorDraft | undefined = undefined;
  @Local failuresShown: boolean = false;
  @Local failures: GeoResourceStatus[] = [];
  @Local automaticDraft: boolean | undefined = undefined;
  @Local submitting: boolean = false;
  @Local providerMenuShown: boolean = false;
  @Local providerMenuTarget: RuntimeProviderRowModel | undefined = undefined;
  @Local geoMenuShown: boolean = false;
  @Local geoMenuTarget: GeoResourceStatus | undefined = undefined;
  private providerMenuChoice: '' | 'refresh' | 'replace' = '';
  private geoMenuChoice: '' | 'sync' | 'edit' | 'copy' = '';
  private active: boolean = false;
  private generation: number = 0;
  private consumedNotice: number = 0;
  private consumedProviderNotice: number = 0;
  private actionOpen: boolean = false;

  aboutToDisappear(): void {
    this.shown = false;
    this.syncLifecycle();
  }

  @Monitor('foreground', 'conn.state', 'conn.forward', 'conn.bootId', 'conn.tunAttached',
    'conn.listenersOpen', 'conn.sessionMode', 'conn.coreReady', 'conn.configRevision')
  syncLifecycle(): void {
    this.store.setConnection(this.conn.connected && !this.conn.busy, this.conn.bootId);
    this.providers.setConnection(this.conn.coreReady && !this.conn.busy, this.conn.connected && !this.conn.busy,
      this.conn.bootId, this.conn.configRevision);
    const visible = this.shown && this.foreground;
    this.store.setVisible(visible);
    this.providers.setVisible(visible);
    if (visible === this.active) { return; }
    this.active = visible;
    ++this.generation;
    if (visible) {
      this.restore(this.generation);
    } else {
      this.failuresShown = false;
      this.failures = [];
      this.providerMenuShown = false;
      this.providerMenuTarget = undefined;
      this.providerMenuChoice = '';
      this.geoMenuShown = false;
      this.geoMenuTarget = undefined;
      this.geoMenuChoice = '';
      this.store.clearNotice();
      this.providers.clearNotice();
      this.automaticDraft = undefined;
      this.submitting = false;
    }
  }

  private async restore(generation: number): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.providers.load(context);
    this.loadScripts(context, generation);
    try {
      await this.store.load(context);
    } catch (error) {
      if (this.isCurrent(generation)) { this.toast(geoErrorText((error as Error).message)); }
    }
  }

  private async loadScripts(context: common.UIAbilityContext, generation: number): Promise<void> {
    try {
      const snapshot = await readConfigScripts(context.filesDir);
      if (this.isCurrent(generation)) {
        this.remoteScripts = snapshot.scripts.filter((item: ConfigScript): boolean => item.url !== '');
      }
    } catch (error) {
      if (this.isCurrent(generation)) { this.toast($r('app.string.script_err_store')); }
    }
  }

  private async syncScripts(items: ConfigScript[]): Promise<void> {
    if (this.syncingScript !== '' || items.length === 0) { return; }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const generation = this.generation;
    for (const item of items) {
      if (!this.isCurrent(generation)) { break; }
      this.syncingScript = item.id;
      let saved = false;
      try {
        const snapshot = await fetchConfigScript(context, item.url, item);
        saved = true;
        if (this.isCurrent(generation)) {
          this.remoteScripts = snapshot.scripts.filter((script: ConfigScript): boolean => script.url !== '');
        }
        await applyConfigScript(context.filesDir, snapshot, '', item.id);
        if (items.length === 1 && this.isCurrent(generation)) { this.toast($r('app.string.script_synced')); }
      } catch (error) {
        if (this.isCurrent(generation)) {
          this.toast(saved ? $r('app.string.script_saved_apply_error', item.name) :
            $r('app.string.script_sync_error', item.name));
        }
      }
    }
    this.syncingScript = '';
  }

  private syncAll(): void {
    if (this.store.canSync) { this.syncResources(GEO_RESOURCE_IDS); }
    this.syncScripts(this.remoteScripts);
  }

  private isCurrent(generation: number): boolean {
    return this.active && generation === this.generation;
  }

  private toast(message: ResourceStr): void {
    if (this.active) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }

  @Monitor('store.noticeSerial')
  consumeNotice(): void {
    if (this.consumedNotice === this.store.noticeSerial) { return; }
    this.consumedNotice = this.store.noticeSerial;
    const notice = this.store.notice;
    this.store.clearNotice();
    if (!this.active || notice === undefined) { return; }
    if (notice.kind === 'saved') {
      this.toast($r('app.string.geo_saved'));
    } else if (notice.kind === 'pending') {
      this.toast($r('app.string.geo_saved_pending'));
    } else if (notice.kind === 'error') {
      this.toast(geoErrorText(notice.error));
    } else if (notice.kind === 'single') {
      const item = notice.items[0];
      if (item === undefined) { return; }
      if (item.outcome === 'updated') { this.toast($r('app.string.geo_updated', item.id.toUpperCase())); }
      else if (item.outcome === 'unchanged') { this.toast($r('app.string.geo_unchanged', item.id.toUpperCase())); }
      else { this.toast(geoErrorText(item.outcome === 'canceled' ? 'geo_canceled' : item.error)); }
    } else if (notice.kind === 'batch') {
      const failed = notice.items.filter((item: GeoResourceStatus): boolean =>
        item.outcome === 'failed' || item.outcome === 'canceled');
      this.toast($r('app.string.geo_batch_result', notice.items.length - failed.length, failed.length));
      this.failures = failed;
      this.presentFailures();
    }
  }

  private presentFailures(): void {
    if (this.active && !this.editing && !this.actionOpen && this.failures.length > 0) {
      this.failuresShown = true;
    }
  }

  private source(urls: GeoUrls, resourceId: GeoResourceId): string {
    switch (resourceId) {
      case 'mmdb': return urls.mmdb;
      case 'asn': return urls.asn;
      case 'geoip': return urls.geoip;
      case 'geosite': return urls.geosite;
    }
  }

  private openUrl(resourceId: GeoResourceId): void {
    if (!this.active || !this.store.loaded || this.store.saving || this.store.settingsError !== '') { return; }
    this.draft = new GeoEditorDraft('url', resourceId, this.store.settings.revision,
      this.source(this.store.settings.urls, resourceId));
    this.editing = true;
  }

  private openInterval(): void {
    if (!this.active || !this.store.loaded || this.store.saving || this.store.settingsError !== '') { return; }
    this.draft = new GeoEditorDraft('interval', 'mmdb', this.store.settings.revision,
      `${this.store.settings.intervalHours}`);
    this.editing = true;
  }

  private restoreDraft(): void {
    const draft = this.draft;
    if (draft === undefined || this.store.saving) { return; }
    draft.text = this.source(GEO_DEFAULT_URLS, draft.resourceId);
    draft.error = '';
  }

  private async saveDraft(): Promise<void> {
    const draft = this.draft;
    if (draft === undefined || this.store.saving || !draft.validate()) { return; }
    try {
      if (draft.mode === 'url') {
        await this.store.saveUrl(draft.resourceId, draft.text, draft.revision);
      } else {
        await this.store.saveInterval(Number(draft.text), draft.revision);
      }
      draft.original = draft.text;
      if (this.draft === draft) { this.editing = false; }
    } catch (error) {
      draft.error = (error as Error).message;
      if (draft.error === 'geo_settings_conflict') {
        // 保留输入，让用户看过冲突提示后再次确认；下一次提交仍接受磁盘修订检查。
        draft.revision = this.store.settings.revision;
      }
    }
  }

  private dismissEditor(dismiss: () => void): void {
    if (this.store.saving || this.actionOpen) { return; }
    if (this.draft === undefined || !this.draft.changed()) { dismiss(); return; }
    const generation = this.generation;
    let discard = false;
    this.actionOpen = true;
    this.getUIContext().showActionSheet({
      title: $r('app.string.geo_unsaved_title'), message: $r('app.string.geo_unsaved_message'),
      alignment: DialogAlignment.Bottom, systemMaterial: this.appStyle.sheetMaterial(), autoCancel: true,
      sheets: [{ title: $r('app.string.geo_discard'), action: (): void => { discard = true; } }],
      confirm: { value: $r('app.string.geo_keep_editing'), defaultFocus: true, action: (): void => {} },
      onWillDismiss: (action: DismissDialogAction): void => action.dismiss(),
      onDidDisappear: (): void => {
        this.actionOpen = false;
        if (discard && this.isCurrent(generation)) { dismiss(); }
      }
    });
  }

  private async syncResources(ids: GeoResourceId[]): Promise<void> {
    if (!this.active || !this.store.canSync || this.submitting || (ids.length > 1 && this.updating())) { return; }
    const generation = this.generation;
    this.submitting = true;
    try { await this.store.sync(ids); }
    catch (error) {
      if (this.isCurrent(generation)) { this.toast(geoErrorText((error as Error).message)); }
    }
    finally {
      if (this.isCurrent(generation)) { this.submitting = false; }
    }
  }

  private async copySource(resourceId: GeoResourceId): Promise<void> {
    if (!this.active || this.store.settingsError !== '') { return; }
    const generation = this.generation;
    const source = this.source(this.store.settings.urls, resourceId);
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, source));
      if (this.isCurrent(generation)) { this.toast($r('app.string.geo_link_copied')); }
    } catch (_error) {
      if (this.isCurrent(generation)) { this.toast($r('app.string.geo_copy_failed')); }
    }
  }

  private rowActions(item: GeoResourceStatus): void {
    if (!this.active || this.actionOpen || this.geoMenuShown || this.providerMenuShown ||
      !this.store.loaded || this.store.saving) { return; }
    this.geoMenuTarget = item;
    this.geoMenuChoice = '';
    this.geoMenuShown = true;
  }

  private finishGeoMenu(): void {
    const target = this.geoMenuTarget;
    const choice = this.geoMenuChoice;
    this.geoMenuTarget = undefined;
    this.geoMenuChoice = '';
    if (!this.active || target === undefined) { return; }
    if (choice === 'sync') { this.syncResources([target.id]); }
    else if (choice === 'edit') { this.openUrl(target.id); }
    else if (choice === 'copy') { this.copySource(target.id); }
    this.presentFailures();
  }


  private async saveAutomatic(enabled: boolean): Promise<void> {
    if (!this.active || !this.store.loaded || this.store.saving || this.store.settingsError !== '') { return; }
    const generation = this.generation;
    this.automaticDraft = enabled;
    try { await this.store.saveAutoUpdate(enabled); }
    catch (error) {
      if (this.isCurrent(generation)) { this.toast(geoErrorText((error as Error).message)); }
    }
    finally {
      if (this.isCurrent(generation)) { this.automaticDraft = undefined; }
    }
  }

  private updating(): boolean {
    if (this.submitting) { return true; }
    for (const item of this.store.items) {
      if (item.phase === 'queued' || item.phase === 'updating') { return true; }
    }
    return false;
  }

  private confirmReset(): void {
    if (!this.active || this.actionOpen || this.store.saving) { return; }
    const generation = this.generation;
    let reset = false;
    this.actionOpen = true;
    this.getUIContext().showActionSheet({
      title: $r('app.string.geo_reset_settings'), message: $r('app.string.geo_reset_message'),
      alignment: DialogAlignment.Bottom, systemMaterial: this.appStyle.sheetMaterial(), autoCancel: true,
      sheets: [{ title: $r('app.string.geo_reset_settings'), action: (): void => { reset = true; } }],
      confirm: { value: $r('app.string.action_cancel'), defaultFocus: true, action: (): void => {} },
      onDidDisappear: (): void => {
        this.actionOpen = false;
        if (reset && this.isCurrent(generation)) { this.resetSettings(); }
      }
    });
  }

  private async resetSettings(): Promise<void> {
    const generation = this.generation;
    try { await this.store.resetSettings(); }
    catch (error) {
      if (this.isCurrent(generation)) { this.toast(geoErrorText((error as Error).message)); }
    }
  }

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: $r('app.string.tools_resources') })
  }

  @Builder
  HeaderMenus() {
    Row({ space: HEADER_GAP }) {
      Button({ type: ButtonType.Circle }) {
        if (this.updating() || this.syncingScript !== '') {
          LoadingProgress().width(HEADER_ICON_SIZE).height(HEADER_ICON_SIZE).color($r('sys.color.font_primary'))
            .accessibilityText($r('app.string.geo_updating'))
        } else {
          SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(HEADER_ICON_SIZE)
            .fontColor([$r('sys.color.font_primary')])
        }
      }
      .attributeModifier(HEADER_ACTION)
      .systemMaterial(this.appStyle.headerMaterial())
      .enabled((this.store.canSync || this.remoteScripts.length > 0) && !this.updating() && this.syncingScript === '')
      .accessibilityText($r('app.string.action_update_all'))
      .accessibilityDescription(this.updating() ? $r('app.string.geo_updating') :
        (this.store.canSync ? $r('app.string.action_update_all') : $r('app.string.geo_connect_to_update')))
      .onClick((): void => this.syncAll())
    }
    .height('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ right: PAGE_GUTTER })
  }

  @Builder
  EditorSheet() {
    if (this.draft !== undefined) {
      GeoResourceEditor({ draft: this.draft, saving: this.store.saving,
        onSave: (): void => { this.saveDraft(); },
        onClose: (): void => this.dismissEditor((): void => { this.editing = false; }),
        onRestore: (): void => { this.restoreDraft(); } })
    }
  }

  @Builder
  FailureSheet() {
    Scroll() {
      Column({ space: 16 }) {
        Text($r('app.string.geo_failures')).fontFamily(this.appStyle.fontFamily).fontSize(COMPACT_TITLE_SIZE)
          .lineHeight(COMPACT_TITLE_LINE_HEIGHT).fontWeight(600)
        ForEach(this.failures, (item: GeoResourceStatus) => {
          Column({ space: 4 }) {
            Text(item.id.toUpperCase()).fontFamily(this.appStyle.fontFamily).fontSize(17)
            Text(geoErrorText(item.outcome === 'canceled' ? 'geo_canceled' : item.error))
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(13)
              .fontColor($r('app.color.status_error'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }, (item: GeoResourceStatus): string => item.id)
        Button($r('app.string.action_close')).fontFamily(this.appStyle.fontFamily).onClick((): void => { this.failuresShown = false; })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 32 })
    }
    .height('100%')
    .width('100%')
  }

  @Monitor('providers.noticeSerial')
  consumeProviderNotice(): void {
    if (this.consumedProviderNotice === this.providers.noticeSerial) { return; }
    this.consumedProviderNotice = this.providers.noticeSerial;
    const notice = this.providers.notice;
    this.providers.clearNotice();
    if (!this.active || notice === undefined) { return; }
    if (notice.kind === 'updated') {
      this.toast($r('app.string.provider_updated', notice.name));
    } else if (notice.kind === 'unchanged') {
      this.toast($r('app.string.provider_unchanged', notice.name));
    } else if (notice.kind === 'replaced') {
      this.toast($r('app.string.provider_replaced', notice.name));
    } else {
      this.toast(providerErrorText(notice.error));
    }
  }

  private async pickAndReplaceProvider(item: RuntimeProviderRowModel): Promise<void> {
    if (!this.active || !this.providers.canReplaceLocal || this.providers.isBusy(item.kind, item.name)) { return; }
    const generation = this.generation;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let uri: string | undefined;
    try {
      uri = await pickDocumentFile(context);
    } catch (_error) {
      if (this.isCurrent(generation)) { this.toast($r('app.string.provider_err_io')); }
      return;
    }
    if (!this.isCurrent(generation) || uri === undefined || uri === '') { return; }
    await this.providers.replaceProvider(item.kind, item.name, uri);
  }

  private providerActions(item: RuntimeProviderRowModel): void {
    if (!this.active || this.actionOpen || this.providerMenuShown || this.geoMenuShown ||
      this.providers.isBusy(item.kind, item.name)) { return; }
    const canRefresh = item.updatable && this.providers.canRefreshRemote;
    const canReplace = item.replaceable && this.providers.canReplaceLocal;
    if (!canRefresh && !canReplace) { return; }
    this.providerMenuTarget = item;
    this.providerMenuChoice = '';
    this.providerMenuShown = true;
  }

  private finishProviderMenu(): void {
    const target = this.providerMenuTarget;
    const choice = this.providerMenuChoice;
    this.providerMenuTarget = undefined;
    this.providerMenuChoice = '';
    if (!this.active || target === undefined) { return; }
    if (choice === 'refresh') {
      this.providers.refreshProvider(target.kind, target.name);
    } else if (choice === 'replace') {
      this.pickAndReplaceProvider(target);
    }
  }

  @Builder
  private ActionMenuButton(label: Resource, icon: Resource, onSelect: () => void) {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.NORMAL, stateEffect: true }) {
      Row({ space: 12 }) {
        SymbolGlyph(icon).fontSize(22).fontColor([$r('sys.color.font_primary')])
        Text(label)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(17)
          .lineHeight(24)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius(20)
    .onClick((): void => { onSelect(); })
  }

  @Builder
  private ProviderActionSheet() {
    Column({ space: 10 }) {
      if (this.providerMenuTarget !== undefined) {
        Text(this.providerMenuTarget.kind === 'proxy' ?
          $r('app.string.provider_proxy_section') : $r('app.string.provider_rule_section'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 4 })
        if (this.providerMenuTarget.updatable && this.providers.canRefreshRemote) {
          this.ActionMenuButton($r('app.string.action_update'), $r('sys.symbol.arrow_clockwise'), (): void => {
            this.providerMenuChoice = 'refresh';
            this.providerMenuShown = false;
          })
        }
        if (this.providerMenuTarget.replaceable && this.providers.canReplaceLocal) {
          this.ActionMenuButton($r('app.string.provider_replace_file'), $r('sys.symbol.doc_text'), (): void => {
            this.providerMenuChoice = 'replace';
            this.providerMenuShown = false;
          })
        }
      }
      Button($r('app.string.action_cancel'))
        .fontFamily(this.appStyle.fontFamily)
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .margin({ top: 4 })
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick((): void => {
          this.providerMenuChoice = '';
          this.providerMenuShown = false;
        })
    }
    .width('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 4, bottom: 24 })
  }

  @Builder
  private GeoActionSheet() {
    Column({ space: 10 }) {
      if (this.geoMenuTarget !== undefined) {
        Text(this.store.canSync ? $r('app.string.geo_row_actions') : $r('app.string.geo_connect_to_update'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 4 })
        if (this.store.canSync && this.geoMenuTarget.phase === 'idle') {
          this.ActionMenuButton($r('app.string.action_update'), $r('sys.symbol.arrow_clockwise'), (): void => {
            this.geoMenuChoice = 'sync';
            this.geoMenuShown = false;
          })
        }
        if (this.store.settingsError === '') {
          this.ActionMenuButton($r('app.string.action_edit'), $r('sys.symbol.pencil_line'), (): void => {
            this.geoMenuChoice = 'edit';
            this.geoMenuShown = false;
          })
          this.ActionMenuButton($r('app.string.action_copy_link'), $r('sys.symbol.rectangle_on_rectangle'), (): void => {
            this.geoMenuChoice = 'copy';
            this.geoMenuShown = false;
          })
        }
      }
      Button($r('app.string.action_cancel'))
        .fontFamily(this.appStyle.fontFamily)
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .margin({ top: 4 })
        .buttonStyle(ButtonStyleMode.NORMAL)
        .onClick((): void => {
          this.geoMenuChoice = '';
          this.geoMenuShown = false;
        })
    }
    .width('100%')
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 4, bottom: 24 })
  }

  @Builder
  private ResourceSkeletonCard(rows: number) {
    Column() {
      ForEach(Array.from<number, number>({ length: rows }, (_v: number, idx: number): number => idx),
        (index: number) => {
          if (index > 0) {
            Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
          }
          Row({ space: 12 }) {
            Column({ space: 8 }) {
              Row()
                .width('42%')
                .height(18)
                .borderRadius(5)
                .backgroundColor(this.appStyle.palette.track)
                .opacity(0.55)
              Row()
                .width('64%')
                .height(14)
                .borderRadius(4)
                .backgroundColor(this.appStyle.palette.track)
                .opacity(0.55)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Row()
              .width(48)
              .height(22)
              .borderRadius(8)
              .backgroundColor(this.appStyle.palette.track)
              .opacity(0.55)
          }
          .width('100%')
          .constraintSize({ minHeight: 68 })
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        }, (index: number): string => `skeleton-${index}`)
    }
    .width('100%')
    .borderRadius(22)
    .clip(true)
    .backgroundColor(this.appStyle.palette.cardBackground)
  }

  @Builder
  private RuntimeProviderList(title: Resource, items: RuntimeProviderRowModel[]) {
    if (items.length > 0) {
      Text(title).fontFamily(this.appStyle.fontFamily).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_secondary')).width('100%').padding({ left: 16, right: 16 })
      Column() {
        ForEach(items, (item: RuntimeProviderRowModel, index: number) => {
          if (index > 0) {
            Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
          }
          RuntimeProviderRow({
            item: item,
            now: this.store.now,
            canRefresh: this.providers.canRefreshRemote,
            canReplace: this.providers.canReplaceLocal,
            onRefresh: (): void => { this.providers.refreshProvider(item.kind, item.name); },
            onActions: (): void => { this.providerActions(item); }
          })
        }, (item: RuntimeProviderRowModel): string => item.key)
      }
      .width('100%')
      .borderRadius(22)
      .clip(true)
      .backgroundColor(this.appStyle.palette.cardBackground)
    }
  }

  @Builder
  private RuntimeProvidersSection() {
    if (!this.providers.ready) {
      Text($r('app.string.provider_section_title')).fontFamily(this.appStyle.fontFamily).fontSize(14)
        .fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary')).width('100%')
        .padding({ left: 16, right: 16 })
      Column({ space: 4 }) {
        Text($r('app.string.provider_not_ready_title')).fontFamily(this.appStyle.fontFamily).fontSize(15)
          .fontColor($r('sys.color.font_primary'))
        Text($r('app.string.provider_not_ready_hint')).fontFamily(this.appStyle.fontFamily).fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .borderRadius(22)
      .backgroundColor(this.appStyle.palette.cardBackground)
    } else if (!this.providers.loaded) {
      Text($r('app.string.provider_section_title')).fontFamily(this.appStyle.fontFamily).fontSize(14)
        .fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary')).width('100%')
        .padding({ left: 16, right: 16 })
      this.ResourceSkeletonCard(2)
    } else if (this.providers.error !== '') {
      Text($r('app.string.provider_section_title')).fontFamily(this.appStyle.fontFamily).fontSize(14)
        .fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary')).width('100%')
        .padding({ left: 16, right: 16 })
      Text(providerErrorText(this.providers.error)).fontFamily(this.appStyle.fontFamily).fontSize(13)
        .fontColor($r('app.color.status_error')).width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .borderRadius(22)
        .backgroundColor(this.appStyle.palette.cardBackground)
    } else if (!this.providers.hasProviders) {
      Text($r('app.string.provider_section_title')).fontFamily(this.appStyle.fontFamily).fontSize(14)
        .fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary')).width('100%')
        .padding({ left: 16, right: 16 })
      Column({ space: 4 }) {
        Text($r('app.string.provider_empty_title')).fontFamily(this.appStyle.fontFamily).fontSize(15)
          .fontColor($r('sys.color.font_primary'))
        Text($r('app.string.provider_empty_hint')).fontFamily(this.appStyle.fontFamily).fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .borderRadius(22)
      .backgroundColor(this.appStyle.palette.cardBackground)
    } else {
      this.RuntimeProviderList($r('app.string.provider_proxy_section'), this.providers.proxyItems)
      this.RuntimeProviderList($r('app.string.provider_rule_section'), this.providers.ruleItems)
      if (!this.providers.connected) {
        Text($r('app.string.provider_connect_to_refresh')).fontFamily(this.appStyle.fontFamily).fontSize(13)
          .fontColor($r('sys.color.font_secondary')).width('100%').padding({ left: 16, right: 16 })
      }
    }
  }

  @Builder
  ScriptResources() {
    if (this.remoteScripts.length > 0) {
      Text($r('app.string.script_title')).fontFamily(this.appStyle.fontFamily).fontSize(14).fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_secondary')).width('100%').padding({ left: 16, right: 16 })
      Column() {
        ForEach(this.remoteScripts, (item: ConfigScript, index: number) => {
          if (index > 0) { Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 }) }
          Row({ space: 8 }) {
            Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.NORMAL }) {
              Column({ space: 4 }) {
                Text(item.name).fontFamily(this.appStyle.fontFamily).fontSize(16).fontColor($r('sys.color.font_primary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(item.url).fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('sys.color.font_secondary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.width('100%').alignItems(HorizontalAlign.Start)
            }.layoutWeight(1).height(56).padding(0).backgroundColor(Color.Transparent)
              .enabled(this.syncingScript === '').onClick((): void => this.onScript(item.id))
            Text(formatUpdatedAgo(item.updatedAt, this.store.now)).fontSize(13).fontColor($r('sys.color.font_secondary'))
            Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.NORMAL }) {
              if (this.syncingScript === item.id) {
                LoadingProgress().width(22).height(22).color(this.appStyle.palette.brand)
              } else {
                SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(20).fontColor([$r('sys.color.font_secondary')])
              }
            }.width(40).height(40).backgroundColor(Color.Transparent).enabled(this.syncingScript === '')
              .accessibilityText($r('app.string.script_sync')).onClick((): void => { this.syncScripts([item]); })
          }.width('100%').height(64).padding({ left: 16, right: 8 })
        }, (item: ConfigScript): string => item.id)
      }.width('100%').borderRadius(22).clip(true).backgroundColor(this.appStyle.palette.cardBackground)
    }
  }

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Column({ space: 16 }) {
            if (!this.store.loaded) {
              this.ResourceSkeletonCard(4)
            } else {
              Column() {
                Row({ space: 16 }) {
                  Text($r('app.string.geo_auto_update')).fontFamily(this.appStyle.fontFamily).fontSize(17)
                    .fontColor($r('sys.color.font_primary')).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch,
                    isOn: this.automaticDraft ?? this.store.settings.autoUpdate })
                    .enabled(this.store.loaded && !this.store.saving && this.store.settingsError === '')
                    .accessibilityText($r('app.string.geo_auto_update'))
                    .onChange((enabled: boolean): void => { this.saveAutomatic(enabled); })
                }
                .width('100%')
                .constraintSize({ minHeight: 64 })
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                if (this.automaticDraft ?? this.store.settings.autoUpdate) {
                  Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
                  Button({ type: ButtonType.Normal }) {
                    Row({ space: 12 }) {
                      Text($r('app.string.geo_interval')).fontFamily(this.appStyle.fontFamily).fontSize(17)
                        .fontColor($r('sys.color.font_primary')).layoutWeight(1)
                      Text($r('app.string.geo_interval_value', this.store.settings.intervalHours)).fontFamily(this.appStyle.fontFamily).fontSize(14)
                        .fontColor($r('sys.color.font_secondary'))
                      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16)
                        .fontColor([$r('sys.color.font_tertiary')])
                    }
                    .width('100%')
                    .constraintSize({ minHeight: 64 })
                    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                  }
                  .width('100%').borderRadius(0).buttonStyle(ButtonStyleMode.NORMAL)
                  .backgroundColor(Color.Transparent)
                  .enabled(this.store.loaded && !this.store.saving && this.store.settingsError === '')
                  .accessibilityText($r('app.string.geo_interval'))
                  .onClick((): void => { this.openInterval(); })
                }
              }
              .width('100%').borderRadius(22).clip(true).backgroundColor(this.appStyle.palette.cardBackground)
              Text($r('app.string.geo_section_title')).fontFamily(this.appStyle.fontFamily).fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_secondary')).padding({ left: 16, right: 16 })
              Column() {
                ForEach(this.store.items, (item: GeoResourceItem, index: number) => {
                  if (index > 0) {
                    Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
                  }
                  GeoResourceRow({ item: item, now: this.store.now, canSync: this.store.canSync,
                    onEdit: (): void => { this.openUrl(item.id); },
                    onActions: (): void => { this.rowActions(item); } })
                }, (item: GeoResourceItem): string => item.id)
              }
              .width('100%')
              .borderRadius(22)
              .clip(true)
              .backgroundColor(this.appStyle.palette.cardBackground)
            }
            this.RuntimeProvidersSection()
            this.ScriptResources()
            if (this.store.settingsError !== '') {
              Column({ space: 12 }) {
                Text(geoErrorText(this.store.settingsError)).fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('app.color.status_error'))
                Button($r('app.string.geo_reset_settings'))
                  .fontFamily(this.appStyle.fontFamily)
                  .buttonStyle(ButtonStyleMode.NORMAL)
                  .enabled(!this.store.saving)
                  .onClick((): void => { this.confirmReset(); })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            if (this.store.error !== '') {
              Text(geoErrorText(this.store.error)).fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('app.color.status_error')).width('100%')
            }
            if (this.store.pendingApply) {
              Text($r('app.string.geo_saved_pending')).fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
            }
            if (!this.store.canSync) {
              Text($r('app.string.geo_connect_to_update')).fontFamily(this.appStyle.fontFamily).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
            }
          }
          .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 32 })
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .bindSheet($$this.editing, this.EditorSheet, {
          height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: false,
          keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
          onWillDismiss: (action: DismissSheetAction): void => this.dismissEditor((): void => action.dismiss()),
          onDisappear: (): void => { this.draft = undefined; this.presentFailures(); }
        })
        Column().bindSheet($$this.failuresShown, this.FailureSheet, {
          height: SheetSize.MEDIUM, systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
          onDisappear: (): void => { this.failures = []; }
        })
        Column().bindSheet($$this.providerMenuShown, this.ProviderActionSheet, {
          title: { title: this.providerMenuTarget?.name ?? '' },
          height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM,
          systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
          onDisappear: (): void => { this.finishProviderMenu(); }
        })
        Column().bindSheet($$this.geoMenuShown, this.GeoActionSheet, {
          title: { title: this.geoMenuTarget?.id.toUpperCase() ?? '' },
          height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM,
          systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
          onDisappear: (): void => { this.finishGeoMenu(); }
        })
      }
      .width('100%')
      .height('100%')
    }
    .title(this.HeaderTitle, { systemMaterial: this.appStyle.regularMaterial() })
    .menus(this.HeaderMenus)
    .padding({ top: this.topInset })
    .backgroundColor(this.appStyle.palette.pageBackground)
    .onShown((_reason: VisibilityChangeReason): void => { this.shown = true; this.syncLifecycle(); })
    .onHidden((_reason: VisibilityChangeReason): void => { this.shown = false; this.syncLifecycle(); })
  }
}
