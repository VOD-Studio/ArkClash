import { common } from '@kit.AbilityKit';
import { BackgroundKeep, backgroundKeep } from '../../client/BackgroundKeep';
import { Connection, connection } from '../../client/Connection';
import { readVpnNetworkSettings, saveVpnNetworkSettings } from '../../client/VpnNetworkSettings';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ScrollDestination } from '../../components/ScrollDestination';
import { ListRow } from '../../components/ListRow';
import { PAGE_GUTTER } from '../../components/Theme';
import {
  MAX_ROUTE_ENTRIES, MAX_TUN_MTU, MAX_VPN_EXCLUDED_APPS, minTunMtu, TUN_CONGESTION_CONTROLLERS, TUN_STACKS,
  vpnExcludedApplications, VpnNetworkSettings
} from '../../shared/VpnNetwork';
import { SettingsSection } from './SettingsSection';

enum NetworkEditor {
  Stack,
  Mtu,
  Congestion,
  Routes,
  Exclusions,
  ExcludedApps
}

let cachedNetworkSettings: VpnNetworkSettings | undefined = undefined;

@ComponentV2
export struct NetworkPage {
  @Param foreground: boolean = true;
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private conn: Connection = connection;
  @Local private keep: BackgroundKeep = backgroundKeep;
  @Local private keepSaving: boolean = false;
  @Local private settings: VpnNetworkSettings =
    cachedNetworkSettings !== undefined ? cachedNetworkSettings.copy() : new VpnNetworkSettings();
  @Local private loading: boolean = cachedNetworkSettings === undefined;
  @Local private loadFailed: boolean = false;
  @Local private saving: boolean = false;
  @Local private editing: boolean = false;
  @Local private editKind: NetworkEditor = NetworkEditor.Stack;
  @Local private draft: string = '';
  @Local private editError: ResourceStr = '';
  private active: boolean = false;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private toast(message: ResourceStr): void {
    if (this.active && this.foreground) {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private async load(): Promise<void> {
    const silent = cachedNetworkSettings !== undefined;
    if (!silent) {
      this.loading = true;
    }
    try {
      const loaded = await readVpnNetworkSettings(this.context());
      cachedNetworkSettings = loaded.copy();
      this.settings = loaded;
      this.loadFailed = false;
    } catch (_error) {
      if (!silent) {
        this.loadFailed = true;
      }
    } finally {
      this.loading = false;
    }
  }

  private editable(): boolean {
    return !this.loading && !this.loadFailed && !this.saving && !this.conn.busy;
  }

  private async changeVpn(isOn: boolean): Promise<void> {
    try {
      if (isOn) {
        await this.conn.connect(this.context());
      } else {
        await this.conn.disconnect(this.context());
      }
    } catch (error) {
      this.toast((error as Error).message);
    }
  }

  private async save(next: VpnNetworkSettings, inEditor: boolean): Promise<void> {
    if (!this.editable()) {
      return;
    }
    const previous = this.settings;
    this.saving = true;
    if (!inEditor) {
      this.settings = next;
    }
    try {
      await saveVpnNetworkSettings(this.context(), next);
      cachedNetworkSettings = next.copy();
      this.settings = next;
      if (inEditor) {
        this.editing = false;
      }
      this.toast(this.conn.connected ? $r('app.string.network_reconnect') : $r('app.string.network_saved'));
    } catch (error) {
      const message = this.errorText((error as Error).message);
      if (inEditor) {
        this.editError = message;
      } else {
        this.settings = previous;
        this.toast(message);
      }
    } finally {
      this.saving = false;
    }
  }

  private errorText(reason: string): ResourceStr {
    switch (reason) {
      case 'invalid_mtu': return $r('app.string.network_mtu_range', minTunMtu(this.settings.ipv6), MAX_TUN_MTU);
      case 'invalid_cidr': return $r('app.string.network_invalid_cidr');
      case 'too_many_entries': return $r('app.string.network_route_limit', MAX_ROUTE_ENTRIES);
      case 'too_many_routes': return $r('app.string.network_route_expansion');
      case 'invalid_bundle_name': return $r('app.string.network_invalid_bundle');
      case 'too_many_apps': return $r('app.string.network_app_limit', MAX_VPN_EXCLUDED_APPS);
      default: return $r('app.string.network_save_failed');
    }
  }

  private setIPv6(isOn: boolean): void {
    const next = this.settings.copy();
    next.ipv6 = isOn;
    next.mtu = Math.max(next.mtu, minTunMtu(isOn));
    this.save(next, false);
  }

  private setDnsHijacking(isOn: boolean): void {
    const next = this.settings.copy();
    next.dnsHijacking = isOn;
    this.save(next, false);
  }

  private setBypassPrivateRoute(isOn: boolean): void {
    const next = this.settings.copy();
    next.bypassPrivateRoute = isOn;
    this.save(next, false);
  }

  private editorTitle(): ResourceStr {
    switch (this.editKind) {
      case NetworkEditor.Stack: return $r('app.string.network_stack');
      case NetworkEditor.Congestion: return $r('app.string.network_congestion');
      case NetworkEditor.Mtu: return 'MTU';
      case NetworkEditor.Routes: return $r('app.string.network_routes');
      case NetworkEditor.Exclusions: return $r('app.string.network_exclusions');
      case NetworkEditor.ExcludedApps: return $r('app.string.network_excluded_apps');
    }
  }

  private openEditor(kind: NetworkEditor, draft: string = ''): void {
    this.editKind = kind;
    this.draft = draft;
    this.editError = '';
    this.editing = true;
  }

  private chooseOption(option: string): void {
    const next = this.settings.copy();
    if (this.editKind === NetworkEditor.Stack) {
      next.stack = option;
    } else {
      next.congestionController = option;
    }
    this.save(next, true);
  }

  private saveEditor(): void {
    const next = this.settings.copy();
    if (this.editKind === NetworkEditor.Mtu) {
      next.mtu = /^\d{3,4}$/.test(this.draft.trim()) ? Number(this.draft) : 0;
    } else {
      const entries = this.draft.split(/\s+/).filter((entry: string): boolean => entry !== '');
      if (this.editKind === NetworkEditor.Routes) {
        next.routeAddress = entries;
      } else if (this.editKind === NetworkEditor.ExcludedApps) {
        try {
          next.excludedApplications = vpnExcludedApplications(entries, this.context().applicationInfo.name);
        } catch (error) {
          this.editError = this.errorText((error as Error).message);
          return;
        }
      } else {
        next.routeExcludeAddress = entries;
      }
    }
    this.save(next, true);
  }

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: $r('app.string.network_title') })
  }

  @Builder
  Rule() {
    Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
  }

  @Builder
  VpnSwitch() {
    NetworkToggleRow({
      label: $r('app.string.network_vpn'),
      checked: this.conn.intent === 'started' || this.conn.vpnCreated,
      available: !this.conn.busy && !this.saving &&
        (this.conn.intent === 'started' || this.conn.vpnCreated || (!this.loading && !this.loadFailed)),
      onToggle: (isOn: boolean): void => { this.changeVpn(isOn); }
    })
  }

  private async changeKeep(isOn: boolean): Promise<void> {
    if (this.keepSaving) {
      return;
    }
    this.keepSaving = true;
    try {
      await this.keep.setEnabled(this.context(), isOn);
    } catch (error) {
      this.toast((error as Error).message === 'keep_notification_disabled' ?
        $r('app.string.network_keep_alive_notification') : $r('app.string.network_save_failed'));
    } finally {
      this.keepSaving = false;
    }
  }

  private keepStateText(): ResourceStr {
    switch (this.keep.state) {
      case 'suspended': return $r('app.string.network_keep_alive_suspended');
      case 'stopped': return $r('app.string.network_keep_alive_stopped');
      case 'removed': return $r('app.string.network_keep_alive_removed');
      case 'failed': return $r('app.string.network_keep_alive_failed');
      default: return '';
    }
  }

  @Builder
  KeepRows() {
    NetworkToggleRow({
      label: $r('app.string.network_keep_alive'), checked: this.keep.enabled, available: !this.keepSaving,
      onToggle: (isOn: boolean): void => { this.changeKeep(isOn); }
    })
    if (this.keepStateText() !== '') {
      this.Rule()
      ListRow({ title: $r('app.string.network_keep_alive_state'), value: this.keepStateText(), chevron: false })
    }
  }

  @Builder
  VpnRows() {
    ListRow({ title: $r('app.string.network_system_proxy'),
      value: $r('app.string.network_platform_unsupported'), chevron: false }).enabled(false)
    this.Rule()
    ListRow({ title: $r('app.string.network_bypass_domains'),
      value: $r('app.string.network_platform_unsupported'), chevron: false })
      .enabled(false)
    this.Rule()
    ListRow({ title: $r('app.string.network_excluded_apps'), value: this.settings.excludedApplications.length.toString(),
      onTap: (): void => this.openEditor(NetworkEditor.ExcludedApps, this.settings.excludedApplications.join('\n')) })
      .enabled(this.editable())
    this.Rule()
    NetworkToggleRow({
      label: $r('app.string.network_ipv6'), checked: this.settings.ipv6, available: this.editable(),
      onToggle: (isOn: boolean): void => this.setIPv6(isOn)
    })
    this.Rule()
    NetworkToggleRow({
      label: $r('app.string.network_dns_hijacking'), checked: this.settings.dnsHijacking,
      available: this.editable(), onToggle: (isOn: boolean): void => this.setDnsHijacking(isOn)
    })
  }

  @Builder
  StackRow() {
    ListRow({
      title: $r('app.string.network_stack'), value: this.settings.stack,
      onTap: (): void => this.openEditor(NetworkEditor.Stack)
    })
    .enabled(this.editable())
  }

  @Builder
  TunRows() {
    ListRow({
      title: 'MTU', value: this.settings.mtu.toString(),
      onTap: (): void => this.openEditor(NetworkEditor.Mtu, this.settings.mtu.toString())
    })
    .enabled(this.editable())
    if (this.settings.stack === 'mips') {
      this.Rule()
      ListRow({
        title: $r('app.string.network_congestion'), value: this.settings.congestionController,
        onTap: (): void => this.openEditor(NetworkEditor.Congestion)
      })
      .enabled(this.editable())
    }
    this.Rule()
    NetworkToggleRow({
      label: $r('app.string.network_bypass_private'), checked: this.settings.bypassPrivateRoute,
      available: this.editable(), onToggle: (isOn: boolean): void => this.setBypassPrivateRoute(isOn)
    })
    this.Rule()
    ListRow({
      title: $r('app.string.network_routes'), value: this.settings.routeAddress.length.toString(),
      onTap: (): void => this.openEditor(NetworkEditor.Routes, this.settings.routeAddress.join('\n'))
    })
    .enabled(this.editable())
    this.Rule()
    ListRow({
      title: $r('app.string.network_exclusions'), value: this.settings.routeExcludeAddress.length.toString(),
      onTap: (): void => this.openEditor(NetworkEditor.Exclusions, this.settings.routeExcludeAddress.join('\n'))
    })
    .enabled(this.editable())
  }

  @Builder
  Editor() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.editKind === NetworkEditor.Stack || this.editKind === NetworkEditor.Congestion) {
          ForEach(this.editKind === NetworkEditor.Stack ? TUN_STACKS : TUN_CONGESTION_CONTROLLERS,
            (option: string) => {
              ListRow({
                title: option, chevron: false,
                trailingIcon: option === (this.editKind === NetworkEditor.Stack ?
                  this.settings.stack : this.settings.congestionController) ? $r('sys.symbol.checkmark') : undefined,
                onTap: (): void => this.chooseOption(option)
              })
              .enabled(this.editable())
            }, (option: string): string => option)
        } else {
          if (this.editKind === NetworkEditor.Mtu) {
            TextInput({ text: this.draft,
              placeholder: $r('app.string.network_mtu_range', minTunMtu(this.settings.ipv6), MAX_TUN_MTU) })
              .type(InputType.Number)
              .maxLength(4)
              .onChange((input: string): void => { this.draft = input; this.editError = ''; })
          } else {
            Text(this.editKind === NetworkEditor.ExcludedApps ?
              $r('app.string.network_excluded_apps_hint') : $r('app.string.network_route_hint'))
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
            TextArea({ text: this.draft, placeholder: this.editKind === NetworkEditor.ExcludedApps ?
              'com.example.app' : '192.0.2.0/24\n2001:db8::/32' })
              .maxLength(this.editKind === NetworkEditor.ExcludedApps ? 129 * MAX_VPN_EXCLUDED_APPS : 4096)
              .height(160)
              .onChange((input: string): void => { this.draft = input; this.editError = ''; })
          }
          Row({ space: 12 }) {
            Button($r('app.string.action_cancel'))
              .buttonStyle(ButtonStyleMode.NORMAL)
              .layoutWeight(1)
              .enabled(!this.saving)
              .onClick((): void => { this.editing = false; })
            Button($r('app.string.action_save'))
              .layoutWeight(1)
              .enabled(this.editable())
              .onClick((): void => this.saveEditor())
          }
          .width('100%')
        }
        if (this.editError !== '') {
          Text(this.editError)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
    }
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
  }

  build() {
    ScrollDestination({
      heading: (): void => this.HeaderTitle(),
      pageShown: (): void => { this.active = true; this.load(); },
      pageHidden: (): void => { this.active = false; }
    }) {
      Scroll() {
        Column({ space: 16 }) {
          if (this.loadFailed) {
            Button($r('app.string.network_load_retry'))
              .enabled(!this.loading)
              .onClick((): void => { this.load(); })
          }
          SettingsSection({ rows: (): void => this.VpnSwitch() })
          SettingsSection({
            heading: $r('app.string.network_background'), footer: $r('app.string.network_keep_alive_footer'),
            rows: (): void => this.KeepRows()
          })
          SettingsSection({
            heading: 'VPN', footer: $r('app.string.network_platform_limit'),
            rows: (): void => this.VpnRows()
          })
          SettingsSection({ heading: $r('app.string.network_options'), rows: (): void => this.StackRow() })
          SettingsSection({
            heading: 'TUN', footer: $r('app.string.network_applies_on_connect'), rows: (): void => this.TunRows()
          })
        }
        .width('100%')
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .clipContent(ContentClipMode.SAFE_AREA)
      .scrollBar(BarState.Off)
      .bindSheet($$this.editing, this.Editor, {
        title: { title: this.editorTitle() },
        height: this.editKind === NetworkEditor.Routes || this.editKind === NetworkEditor.Exclusions ?
          SheetSize.LARGE : SheetSize.MEDIUM,
        preferType: SheetType.BOTTOM,
        showClose: true,
        systemMaterial: this.appStyle.sheetMaterial()
      })
    }
  }
}

@ComponentV2
struct NetworkToggleRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require label: Resource;
  @Param checked: boolean = false;
  @Param available: boolean = true;
  @Event onToggle: (isOn: boolean) => void = () => {};

  build() {
    Row({ space: 12 }) {
      Text(this.label)
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(16)
        .fontColor(this.available ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.checked })
        .accessibilityText(this.label)
        .selectedColor(this.appStyle.palette.brand)
        .enabled(this.available)
        .onChange((isOn: boolean): void => this.onToggle(isOn))
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16 })
  }
}
