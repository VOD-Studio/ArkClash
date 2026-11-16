import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { connection, Connection } from '../../client/Connection';
import { HEADER_ACTION, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { GEO_DEFAULT_URLS, GEO_RESOURCE_IDS, GeoResourceId, GeoResourceStatus, GeoUrls } from '../../shared/GeoResources';
import { GeoEditorDraft, GeoResourceEditor, geoErrorText } from './GeoResourceEditor';
import { GeoResourceRow } from './GeoResourceRow';
import { GeoResourceItem, ResourcesStore } from './Resources';

@ComponentV2
export struct ResourcesPage {
  @Param foreground: boolean = true;
  @Local store: ResourcesStore = new ResourcesStore();
  @Local conn: Connection = connection;
  @Local shown: boolean = false;
  @Local editing: boolean = false;
  @Local draft: GeoEditorDraft | undefined = undefined;
  @Local failuresShown: boolean = false;
  @Local failures: GeoResourceStatus[] = [];
  private active: boolean = false;
  private generation: number = 0;
  private consumedNotice: number = 0;
  private actionOpen: boolean = false;

  aboutToDisappear(): void {
    this.shown = false;
    this.syncLifecycle();
  }

  @Monitor('foreground', 'conn.state', 'conn.forward', 'conn.bootId', 'conn.tunAttached',
    'conn.listenersOpen', 'conn.sessionMode')
  syncLifecycle(): void {
    this.store.setConnection(this.conn.connected && !this.conn.busy, this.conn.bootId);
    const visible = this.shown && this.foreground;
    this.store.setVisible(visible);
    if (visible === this.active) { return; }
    this.active = visible;
    ++this.generation;
    if (visible) {
      this.restore(this.generation);
    } else {
      this.failuresShown = false;
      this.failures = [];
      this.store.clearNotice();
    }
  }

  private async restore(generation: number): Promise<void> {
    try {
      await this.store.load(this.getUIContext().getHostContext() as common.UIAbilityContext);
    } catch (error) {
      if (this.isCurrent(generation)) { this.toast(geoErrorText((error as Error).message)); }
    }
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
      alignment: DialogAlignment.Bottom, systemMaterial: sheetMaterial(), autoCancel: true,
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
    if (!this.active || !this.store.canSync) { return; }
    const generation = this.generation;
    try { await this.store.sync(ids); }
    catch (error) {
      if (this.isCurrent(generation)) { this.toast(geoErrorText((error as Error).message)); }
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
    if (!this.active || this.actionOpen || !this.store.loaded || this.store.saving) { return; }
    const generation = this.generation;
    let choice = '';
    const sheets: SheetInfo[] = [];
    if (this.store.canSync && item.phase === 'idle') {
      sheets.push({ title: $r('app.string.action_update'), action: (): void => { choice = 'sync'; } });
    }
    if (this.store.settingsError === '') {
      sheets.push({ title: $r('app.string.action_edit'), action: (): void => { choice = 'edit'; } });
      sheets.push({ title: $r('app.string.action_copy_link'), action: (): void => { choice = 'copy'; } });
    }
    this.actionOpen = true;
    this.getUIContext().showActionSheet({
      title: item.id.toUpperCase(), sheets: sheets,
      message: this.store.canSync ? $r('app.string.geo_row_actions') : $r('app.string.geo_connect_to_update'),
      alignment: DialogAlignment.Bottom, systemMaterial: sheetMaterial(), autoCancel: true,
      confirm: { value: $r('app.string.action_cancel'), action: (): void => {} },
      onDidDisappear: (): void => {
        this.actionOpen = false;
        if (!this.isCurrent(generation)) { return; }
        if (choice === 'sync') { this.syncResources([item.id]); }
        else if (choice === 'edit') { this.openUrl(item.id); }
        else if (choice === 'copy') { this.copySource(item.id); }
        this.presentFailures();
      }
    });
  }

  private moreActions(): void {
    if (!this.active || this.actionOpen || !this.store.loaded || this.store.saving || this.store.settingsError !== '') {
      return;
    }
    const generation = this.generation;
    const autoUpdate = !this.store.settings.autoUpdate;
    let choice = '';
    this.actionOpen = true;
    this.getUIContext().showActionSheet({
      title: $r('app.string.action_more'),
      message: $r('app.string.geo_auto_status', this.store.settings.intervalHours),
      alignment: DialogAlignment.Bottom, systemMaterial: sheetMaterial(), autoCancel: true,
      sheets: [
        { title: this.store.settings.autoUpdate ? $r('app.string.geo_disable_auto') : $r('app.string.geo_enable_auto'),
          action: (): void => { choice = 'auto'; } },
        { title: $r('app.string.geo_interval'), action: (): void => { choice = 'interval'; } }
      ],
      confirm: { value: $r('app.string.action_cancel'), action: (): void => {} },
      onDidDisappear: (): void => {
        this.actionOpen = false;
        if (!this.isCurrent(generation)) { return; }
        if (choice === 'auto') { this.saveAutomatic(autoUpdate); }
        else if (choice === 'interval') { this.openInterval(); }
        this.presentFailures();
      }
    });
  }

  private async saveAutomatic(enabled: boolean): Promise<void> {
    const generation = this.generation;
    try { await this.store.saveAutoUpdate(enabled); }
    catch (error) {
      if (this.isCurrent(generation)) { this.toast(geoErrorText((error as Error).message)); }
    }
  }

  private confirmReset(): void {
    if (!this.active || this.actionOpen || this.store.saving) { return; }
    const generation = this.generation;
    let reset = false;
    this.actionOpen = true;
    this.getUIContext().showActionSheet({
      title: $r('app.string.geo_reset_settings'), message: $r('app.string.geo_reset_message'),
      alignment: DialogAlignment.Bottom, systemMaterial: sheetMaterial(), autoCancel: true,
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
  HeaderMenus() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise')).fontSize(20)
          .fontColor([$r('sys.color.font_primary')])
      }
      .attributeModifier(HEADER_ACTION)
      .enabled(this.store.canSync)
      .accessibilityText($r('app.string.action_update_all'))
      .accessibilityDescription(this.store.canSync ? $r('app.string.action_update_all') :
        $r('app.string.geo_connect_to_update'))
      .onClick((): void => { this.syncResources(GEO_RESOURCE_IDS); })
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(20)
          .fontColor([$r('sys.color.font_primary')])
      }
      .attributeModifier(HEADER_ACTION)
      .enabled(this.store.loaded && !this.store.saving && this.store.settingsError === '')
      .accessibilityText($r('app.string.action_more'))
      .onClick((): void => { this.moreActions(); })
    }
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
        Text($r('app.string.geo_failures')).fontSize(22).fontWeight(600)
        ForEach(this.failures, (item: GeoResourceStatus) => {
          Column({ space: 4 }) {
            Text(item.id.toUpperCase()).fontSize(17)
            Text(geoErrorText(item.outcome === 'canceled' ? 'geo_canceled' : item.error))
              .fontSize(13)
              .fontColor($r('app.color.status_error'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }, (item: GeoResourceStatus): string => item.id)
        Button($r('app.string.action_close')).onClick((): void => { this.failuresShown = false; })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 24, bottom: 32 })
    }
    .height('100%')
    .width('100%')
  }

  build() {
    NavDestination() {
      Column() {
        Scroll() {
          Column({ space: 16 }) {
            if (!this.store.loaded) {
              LoadingProgress().width(28).height(28).accessibilityText($r('app.string.geo_loading'))
            } else {
              Column() {
                ForEach(this.store.items, (item: GeoResourceItem, index: number) => {
                  if (index > 0) {
                    Divider().color($r('app.color.divider')).margin({ left: 16, right: 16 })
                  }
                  GeoResourceRow({ item: item, now: this.store.now, canSync: this.store.canSync,
                    onEdit: (): void => { this.openUrl(item.id); },
                    onActions: (): void => { this.rowActions(item); } })
                }, (item: GeoResourceItem): string => item.id)
              }
              .width('100%')
              .borderRadius(22)
              .clip(true)
              .backgroundColor($r('app.color.card_background'))
            }
            if (this.store.settingsError !== '') {
              Column({ space: 12 }) {
                Text(geoErrorText(this.store.settingsError)).fontSize(13).fontColor($r('app.color.status_error'))
                Button($r('app.string.geo_reset_settings'))
                  .buttonStyle(ButtonStyleMode.NORMAL)
                  .enabled(!this.store.saving)
                  .onClick((): void => { this.confirmReset(); })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
            if (this.store.error !== '') {
              Text(geoErrorText(this.store.error)).fontSize(13).fontColor($r('app.color.status_error')).width('100%')
            }
            if (this.store.pendingApply) {
              Text($r('app.string.geo_saved_pending')).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
            }
            if (!this.store.canSync) {
              Text($r('app.string.geo_connect_to_update')).fontSize(13).fontColor($r('sys.color.font_secondary')).width('100%')
            }
          }
          .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 32 })
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .width('100%')
        .bindSheet($$this.editing, this.EditorSheet, {
          height: SheetSize.LARGE, systemMaterial: sheetMaterial(), showClose: false,
          onWillDismiss: (action: DismissSheetAction): void => this.dismissEditor((): void => action.dismiss()),
          onDisappear: (): void => { this.draft = undefined; this.presentFailures(); }
        })
        Column().bindSheet($$this.failuresShown, this.FailureSheet, {
          height: SheetSize.MEDIUM, systemMaterial: sheetMaterial(), showClose: true,
          onDisappear: (): void => { this.failures = []; }
        })
      }
      .width('100%')
      .height('100%')
    }
    .title($r('app.string.tools_resources'))
    .menus(this.HeaderMenus)
    .backgroundColor($r('app.color.page_background'))
    .onShown((_reason: VisibilityChangeReason): void => { this.shown = true; this.syncLifecycle(); })
    .onHidden((_reason: VisibilityChangeReason): void => { this.shown = false; this.syncLifecycle(); })
  }
}
