import { common } from '@kit.AbilityKit';
import { AppReleaseAsset, appReleaseUrl, AppUpdateState, appUpdateState } from '../../client/AppUpdate';
import { connection, Connection } from '../../client/Connection';
import { ControllerSocket, ControllerSocketState } from '../../client/ControllerSocket';
import { parseGeoEvent } from '../../client/GeoResources';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { formatBytes } from '../../components/Format';
import { ListRow } from '../../components/ListRow';
import { CARD_RADIUS, HEADER_ACTION, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { GeoResourceStatus } from '../../shared/GeoResources';

@ComponentV2
export struct DashboardLiveStatus {
  @Param visible: boolean = false;
  @Event onOpenResources: () => void = (): void => {};
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private conn: Connection = connection;
  @Local private expanded: boolean = false;
  @Local private resources: GeoResourceStatus[] = [];
  @Local private resourceError: boolean = false;
  @Local private updates: AppUpdateState = appUpdateState;
  @Local private openResources: boolean = false;
  private mounted: boolean = false;
  private socket?: ControllerSocket;
  private observedBoot: string = '';
  private resourceRevision: number = -1;
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.mounted = true;
    this.observeGeo();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.stopGeo();
  }

  @Monitor('visible', 'conn.coreReady', 'conn.bootId')
  observeGeo(): void {
    const boot = this.mounted && this.visible && this.conn.coreReady ? this.conn.bootId : '';
    if (!this.visible) { this.expanded = false; }
    if (this.observedBoot === boot) { return; }
    this.stopGeo();
    if (boot !== '') { this.startGeo(boot); }
  }

  private stopGeo(): void {
    const socket = this.socket;
    this.socket = undefined;
    socket?.stop();
    this.observedBoot = '';
    this.resourceRevision = -1;
    this.resources = [];
    this.resourceError = false;
  }

  private startGeo(boot: string): void {
    this.observedBoot = boot;
    const socket = new ControllerSocket('/arkclash/geo/events', (text: string): void => {
      if (this.socket !== socket) { return; }
      try {
        const snapshot = parseGeoEvent(text);
        if (snapshot.bootId !== boot || snapshot.revision <= this.resourceRevision) { return; }
        this.resourceRevision = snapshot.revision;
        this.resources = snapshot.items;
        this.resourceError = false;
      } catch (_error) {
        socket.fail('geo_invalid_data');
      }
    }, (state: ControllerSocketState): void => {
      if (this.socket !== socket || state === 'open' || state === 'connecting') { return; }
      this.resources = [];
      this.resourceRevision = -1;
      this.resourceError = state === 'failed' || state === 'closed';
    });
    this.socket = socket;
    socket.start(this.context.filesDir);
  }

  private updateNotice(message: ResourceStr): void {
    if (this.visible && this.expanded) {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private async downloadRelease(asset: AppReleaseAsset): Promise<void> {
    try {
      await this.updates.download(this.context, asset.name);
    } catch (error) {
      this.updateNotice((error as Error).message === 'app_update_checksum' ?
        $r('app.string.live_status_checksum_failed') : $r('app.string.live_status_download_failed'));
    }
  }

  private async saveRelease(): Promise<void> {
    try {
      if (await this.updates.save(this.context)) {
        this.updateNotice($r('app.string.live_status_package_saved'));
      }
    } catch (_error) {
      this.updateNotice($r('app.string.live_status_save_failed'));
    }
  }

  private openRelease(): void {
    const tag = this.updates.release?.available ?? '';
    if (tag !== '') {
      this.context.openLink(appReleaseUrl(tag)).catch((): void => {
        if (this.visible && this.expanded) {
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.live_status_release_failed') });
        }
      });
    }
  }

  private startCore(): void {
    this.conn.ensureReady(this.context).catch((): void => {
      if (this.visible && this.expanded) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_start_failed') });
      }
    });
  }

  @Computed
  get downloads(): GeoResourceStatus[] {
    return this.resources.filter((item: GeoResourceStatus): boolean => item.phase !== 'idle');
  }

  @Computed
  get failures(): GeoResourceStatus[] {
    return this.resources.filter((item: GeoResourceStatus): boolean => item.outcome === 'failed');
  }

  @Computed
  get statusCount(): number {
    return this.downloads.length + this.failures.length + (this.conn.coreReady ? 0 : 1) +
      (this.updates.release?.available || this.updates.release?.galleryUpdate ? 1 : 0);
  }

  private coreLabel(): ResourceStr {
    if (this.conn.coreStarting) { return $r('app.string.live_status_core_starting'); }
    if (!this.conn.coreReady) {
      return this.conn.hostState === 'stopped' ? $r('app.string.live_status_core_stopped') :
        $r('app.string.live_status_core_unknown');
    }
    return this.conn.coreVersion === '' ? $r('app.string.live_status_core_ready') : `mihomo ${this.conn.coreVersion}`;
  }

  private updateLabel(): ResourceStr {
    if (this.updates.checking) { return $r('app.string.live_status_checking'); }
    if (this.updates.phase === 'verifying') { return $r('app.string.live_status_verifying'); }
    if (this.updates.phase === 'ready') { return $r('app.string.live_status_download_ready'); }
    if (this.updates.phase === 'downloading') {
      return $r('app.string.live_status_bytes_total', formatBytes(this.updates.received),
        formatBytes(this.updates.asset?.size ?? 0));
    }
    if (this.updates.phase === 'saving') { return $r('app.string.live_status_saving_package'); }
    if (this.updates.checkFailed) { return $r('app.string.live_status_update_failed'); }
    if (this.updates.release?.galleryUpdate) { return $r('app.string.live_status_gallery_available'); }
    if (this.updates.release?.available) {
      return $r('app.string.live_status_update_available', this.updates.release.available);
    }
    if (this.updates.release !== undefined) {
      return $r('app.string.live_status_update_current', this.updates.release.installed);
    }
    return $r('app.string.live_status_check');
  }

  private resourceLabel(): ResourceStr {
    if (this.resourceError) { return $r('app.string.live_status_resources_unavailable'); }
    if (this.downloads.length > 0) { return $r('app.string.live_status_resources_active', this.downloads.length); }
    if (this.failures.length > 0) { return $r('app.string.live_status_resources_failed', this.failures.length); }
    return '';
  }

  @Builder
  DownloadRow(item: GeoResourceStatus) {
    Column({ space: 6 }) {
      Row({ space: 12 }) {
        Text(item.id.toUpperCase()).layoutWeight(1).fontSize(15)
        Text(item.phase === 'queued' ? $r('app.string.geo_queued') : (item.totalBytes ?? 0) > 0 ?
          $r('app.string.live_status_bytes_total', formatBytes(item.receivedBytes ?? 0), formatBytes(item.totalBytes ?? 0)) :
          $r('app.string.live_status_bytes_received', formatBytes(item.receivedBytes ?? 0)))
          .fontSize(13).fontColor($r('sys.color.font_secondary'))
      }.width('100%')
      if (item.phase === 'updating' && (item.totalBytes ?? 0) > 0) {
        Progress({ value: Math.min(item.receivedBytes ?? 0, item.totalBytes ?? 0), total: item.totalBytes })
          .width('100%').color(this.appStyle.palette.brand)
      }
    }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 12 })
  }

  @Builder
  UpdateRows() {
    ListRow({ title: $r('app.string.live_status_app_update'), value: this.updateLabel(), chevron: false,
      onTap: (): void => { this.updates.check(this.context); } })
      .enabled(!this.updates.checking && this.updates.phase === 'idle')
    if (this.updates.phase === 'downloading') {
      Progress({ value: this.updates.received, total: this.updates.asset?.size ?? 1 })
        .width('100%').padding({ left: 16, right: 16 }).color(this.appStyle.palette.brand)
    }
    if (this.updates.phase === 'ready') {
      ListRow({ title: $r('app.string.live_status_save_package'), onTap: (): void => { this.saveRelease(); } })
    }
    if (this.updates.phase === 'downloading' || this.updates.phase === 'verifying' || this.updates.phase === 'ready') {
      ListRow({ title: $r('app.string.action_cancel'), chevron: false,
        onTap: (): void => { this.updates.cancel(); } })
    } else if (this.updates.phase === 'idle' && this.updates.release?.galleryUpdate) {
      ListRow({ title: $r('app.string.live_status_install_update'), onTap: (): void => {
        this.updates.install(this.context).catch((): void => {
          this.updateNotice($r('app.string.live_status_install_failed'));
        });
      } }).enabled(!this.updates.checking)
    } else if (this.updates.phase === 'idle' && this.updates.release?.available) {
      ForEach(this.updates.release?.assets ?? [], (asset: AppReleaseAsset): void => {
        ListRow({ title: asset.name.endsWith('-unsigned.hap') ? $r('app.string.live_status_download_unsigned') :
          $r('app.string.live_status_download_debug'), value: formatBytes(asset.size),
          onTap: (): void => { this.downloadRelease(asset); } }).enabled(!this.updates.checking)
      }, (asset: AppReleaseAsset): string => asset.name)
      ListRow({ title: $r('app.string.live_status_view_release'), onTap: (): void => this.openRelease() })
    }
  }

  @Builder
  StatusSheet() {
    Scroll() {
      Column({ space: 12 }) {
        Column() {
          ListRow({ title: $r('app.string.about_core'), value: this.coreLabel(), chevron: false })
          if (!this.conn.coreReady && !this.conn.coreStarting && !this.conn.busy) {
            ListRow({ title: $r('app.string.live_status_start_core'), onTap: (): void => this.startCore() })
          }
        }.width('100%').borderRadius(CARD_RADIUS).backgroundColor(this.appStyle.palette.cardBackground)
        Column() {
          this.UpdateRows()
        }.width('100%').borderRadius(CARD_RADIUS).backgroundColor(this.appStyle.palette.cardBackground)
        Column() {
          ListRow({ title: $r('app.string.tools_resources'), value: this.resourceLabel(), onTap: (): void => {
            this.openResources = true;
            this.expanded = false;
          } })
          Repeat(this.downloads).each((item: RepeatItem<GeoResourceStatus>): void => {
            this.DownloadRow(item.item)
          }).key((item: GeoResourceStatus): string => item.operationId)
          ForEach(this.failures, (item: GeoResourceStatus) => {
            ListRow({ title: item.id.toUpperCase(), value: $r('app.string.live_status_resource_failed'),
              chevron: false })
          }, (item: GeoResourceStatus): string => item.operationId)
        }.width('100%').borderRadius(CARD_RADIUS).backgroundColor(this.appStyle.palette.cardBackground)
      }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
    }.width('100%').align(Alignment.Top).scrollBar(BarState.Off)
  }

  build() {
    Button({ type: ButtonType.Circle }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        SymbolGlyph(this.conn.coreStarting ? $r('sys.symbol.waveform_path_ecg_square') :
          !this.conn.coreReady ? $r('sys.symbol.exclamationmark_circle') :
          this.downloads.length > 0 ? $r('sys.symbol.arrow_down_to_line') : $r('sys.symbol.checkmark_circle'))
          .fontSize(HEADER_ICON_SIZE)
          .fontColor([this.conn.coreReady ? this.appStyle.palette.brand : $r('sys.color.icon_primary')])
        if (this.statusCount > 0) {
          Text(this.statusCount.toString()).fontSize(9).fontWeight(600)
            .fontColor(this.appStyle.palette.onBrand).backgroundColor(this.appStyle.palette.brand)
            .borderRadius(8).padding({ left: 4, right: 4, top: 1, bottom: 1 }).offset({ x: 6, y: -4 })
        }
      }
    }
    .attributeModifier(HEADER_ACTION)
    .systemMaterial(this.appStyle.headerMaterial())
    .accessibilityText(this.statusCount > 0 ? $r('app.string.live_status_count', this.statusCount) :
      $r('app.string.live_status_title'))
    .onClick((): void => { this.expanded = true; })
    .bindSheet($$this.expanded, this.StatusSheet, {
      title: { title: $r('app.string.live_status_title') }, height: SheetSize.LARGE, showClose: true,
      systemMaterial: this.appStyle.sheetMaterial(),
      onDisappear: (): void => {
        if (this.openResources) { this.openResources = false; this.onOpenResources(); }
      }
    })
  }
}
