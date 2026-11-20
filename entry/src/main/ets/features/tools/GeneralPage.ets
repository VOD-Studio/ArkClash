import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AppUpdateState, appUpdateState } from '../../client/AppUpdate';
import { GeneralSettingsState, generalSettingsState } from '../../client/GeneralSettings';
import { Connection, connection } from '../../client/Connection';
import { appAppearance, AppearanceState } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ListRow } from '../../components/ListRow';
import { PAGE_GUTTER } from '../../components/Theme';
import {
  defaultGeneralPorts, GeneralPorts, GeneralSettings, GENERAL_LEVELS, GENERAL_TIMEOUTS
} from '../../shared/GeneralSettings';
import { SettingsSection } from './SettingsSection';
import { logLevelLabel } from './LogLabels';

type GeneralEditor = 'ports' | 'authentication' | 'controller' | 'userAgent' | 'hosts' | 'level' | 'timeout';

const PORT_LABELS: string[] = ['Mixed', 'HTTP', 'SOCKS', 'Redir', 'TProxy'];

function generatedCredential(length: number): string {
  return util.generateRandomUUID(true).replace(new RegExp('-', 'g'), '').slice(0, length);
}

function formatPorts(ports: GeneralPorts): string[] {
  return [ports.mixed.toString(), ports.http.toString(), ports.socks.toString(), ports.redir.toString(),
    ports.tproxy.toString()];
}

function parseHostRows(raw: string): Record<string, string[]> {
  const hosts: Record<string, string[]> = {};
  for (const row of raw.split('\n')) {
    if (row.trim() === '') { continue; }
    const fields = row.trim().split(new RegExp('[\\s,]+'));
    const domain = fields[0].toLowerCase();
    if (fields.length < 2 || domain === '__proto__' || Object.keys(hosts).includes(domain)) {
      throw new Error('general_settings_invalid');
    }
    hosts[domain] = fields.slice(1);
  }
  return hosts;
}

@ComponentV2
export struct GeneralPage {
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private settings: GeneralSettingsState = generalSettingsState;
  @Local private updates: AppUpdateState = appUpdateState;
  @Local private conn: Connection = connection;
  @Local private isSaving: boolean = false;
  @Local private loadFailed: boolean = false;
  @Local private editing: boolean = false;
  @Local private editor: GeneralEditor = 'ports';
  @Local private editedPorts: string[] = formatPorts(defaultGeneralPorts());
  @Local private authEnabled: boolean = false;
  @Local private username: string = '';
  @Local private password: string = '';
  @Local private panelEnabled: boolean = false;
  @Local private editorText: string = '';
  @Local private editorError: ResourceStr = '';
  private editorRevision: string = '';

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }

  aboutToAppear(): void { this.load(); }

  private async load(): Promise<void> {
    try {
      await this.settings.load(this.context());
      this.loadFailed = false;
    } catch (_error) { this.loadFailed = true; }
  }

  private draft(): GeneralSettings {
    const saved = this.settings.saved;
    return {
      revision: saved.revision, ports: saved.ports, authentication: saved.authentication,
      controllerSecret: saved.controllerSecret, userAgent: saved.userAgent, hosts: saved.hosts,
      delayTimeout: saved.delayTimeout, closeConnections: saved.closeConnections, logLevel: saved.logLevel,
      captureLogs: saved.captureLogs
    };
  }

  private errorLabel(error: Error): Resource {
    const message = error.message;
    if (message.includes('general_settings_port_busy')) { return $r('app.string.general_port_busy'); }
    if (message.includes('general_settings_controller_busy')) { return $r('app.string.general_controller_busy'); }
    if (message.includes('general_settings_unavailable')) { return $r('app.string.general_unavailable'); }
    if (message.includes('general_settings_io')) { return $r('app.string.general_storage_failed'); }
    if (message.includes('general_settings_invalid')) { return $r('app.string.general_invalid'); }
    if (message.includes('general_settings_conflict')) { return $r('app.string.general_conflict'); }
    return $r('app.string.general_save_failed');
  }

  private async save(draft: GeneralSettings, inEditor: boolean = false): Promise<void> {
    if (this.isSaving) { return; }
    this.isSaving = true;
    this.editorError = '';
    try {
      await this.settings.save(this.context(), draft);
      if (inEditor) { this.closeEditor(); }
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.general_saved') });
    } catch (error) {
      const label = this.errorLabel(error as Error);
      if (inEditor) { this.editorError = label; }
      else { this.getUIContext().getPromptAction().showToast({ message: label }); }
      if ((error as Error).message.includes('general_settings_conflict')) { this.load(); }
    } finally {
      this.isSaving = false;
    }
  }

  private openEditor(editor: GeneralEditor): void {
    const saved = this.settings.saved;
    this.editor = editor;
    this.editorRevision = saved.revision;
    this.editorError = '';
    switch (editor) {
      case 'ports':
        this.editedPorts = formatPorts(saved.ports ?? defaultGeneralPorts());
        break;
      case 'authentication':
        this.authEnabled = saved.authentication?.enabled ?? false;
        this.username = saved.authentication?.username ?? '';
        this.password = saved.authentication?.password ?? '';
        break;
      case 'controller':
        this.panelEnabled = saved.controllerSecret !== '';
        this.editorText = saved.controllerSecret;
        break;
      case 'userAgent':
        this.editorText = saved.userAgent;
        break;
      case 'hosts':
        const hosts = saved.hosts;
        this.editorText = hosts === null ? '' :
          Object.keys(hosts).map((domain: string): string => `${domain} ${hosts[domain].join(' ')}`).join('\n');
        break;
    }
    this.editing = true;
  }

  private closeEditor(): void {
    this.editing = false;
    this.password = '';
    this.username = '';
    this.editorText = '';
  }

  private saveEditor(inheritPorts: boolean = false): void {
    const draft = this.draft();
    draft.revision = this.editorRevision;
    try {
      switch (this.editor) {
        case 'ports':
          if (inheritPorts) {
            draft.ports = undefined;
            break;
          }
          const ports = this.editedPorts.map((input: string): number =>
            new RegExp('^[0-9]{1,5}$').test(input) ? Number(input) : -1);
          draft.ports = { mixed: ports[0], http: ports[1], socks: ports[2], redir: ports[3], tproxy: ports[4] };
          break;
        case 'authentication':
          draft.authentication = { enabled: this.authEnabled, username: this.username.trim(), password: this.password };
          break;
        case 'controller':
          if (this.panelEnabled && this.editorText.trim() === '') { throw new Error('general_settings_invalid'); }
          draft.controllerSecret = this.panelEnabled ? this.editorText.trim() : '';
          break;
        case 'userAgent':
          draft.userAgent = this.editorText.trim();
          break;
        case 'hosts':
          const hosts = parseHostRows(this.editorText);
          draft.hosts = Object.keys(hosts).length > 0 ? hosts : null;
          break;
      }
      this.save(draft, true);
    } catch (error) {
      this.editorError = this.errorLabel(error as Error);
    }
  }

  private setSwitch(kind: string, isOn: boolean): void {
    const draft = this.draft();
    if (kind === 'capture') { draft.captureLogs = isOn; }
    else { draft.closeConnections = isOn; }
    this.save(draft);
  }

  private selectLevel(level: string): void {
    const draft = this.draft();
    if (draft.logLevel === level) { this.closeEditor(); return; }
    draft.logLevel = level;
    this.save(draft, true);
  }

  private selectTimeout(ms: number): void {
    const draft = this.draft();
    if (draft.delayTimeout === ms) { this.closeEditor(); return; }
    draft.delayTimeout = ms;
    this.save(draft, true);
  }

  private hostCount(): string {
    const hosts = this.settings.saved.hosts;
    return hosts === null ? '0' : Object.keys(hosts).length.toString();
  }

  private editorTitle(): Resource {
    switch (this.editor) {
      case 'ports': return $r('app.string.general_ports');
      case 'authentication': return $r('app.string.general_auth');
      case 'controller': return $r('app.string.general_controller');
      case 'userAgent': return $r('app.string.general_ua');
      case 'hosts': return $r('app.string.general_hosts');
      case 'level': return $r('app.string.general_log_level');
      case 'timeout': return $r('app.string.general_delay_timeout');
    }
  }

  @Builder
  Header() { DestinationTitle({ titleText: $r('app.string.tools_general') }) }

  @Builder
  Rule() { Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 }) }

  @Builder
  Inbounds() {
    ListRow({ title: $r('app.string.general_ports'),
      value: this.settings.saved.ports === undefined ? $r('app.string.general_inherit') :
        this.settings.saved.ports.mixed.toString(), onTap: (): void => this.openEditor('ports') })
    this.Rule()
    ListRow({ title: $r('app.string.general_auth'),
      value: this.settings.saved.authentication === undefined ? $r('app.string.general_inherit') :
        this.settings.saved.authentication.enabled ? $r('app.string.general_on') : $r('app.string.general_off'),
      onTap: (): void => this.openEditor('authentication') })
    this.Rule()
    ListRow({ title: $r('app.string.general_controller'),
      value: this.settings.saved.controllerSecret === '' ? $r('app.string.general_off') :
        this.conn.coreReady && !this.conn.panelOpen ? $r('app.string.general_controller_pending') : '127.0.0.1:9090',
      onTap: (): void => this.openEditor('controller') })
  }

  @Builder
  Connections() {
    ListRow({ title: $r('app.string.general_delay_timeout'),
      value: $r('app.string.proxy_delay_ms', this.settings.saved.delayTimeout),
      onTap: (): void => this.openEditor('timeout') })
    this.Rule()
    GeneralSwitchRow({ label: $r('app.string.general_close_connections'),
      checked: this.settings.saved.closeConnections ?? true, interactive: !this.isSaving,
      onToggle: (isOn: boolean): void => this.setSwitch('closeConnections', isOn) })
  }

  @Builder
  Requests() {
    ListRow({ title: $r('app.string.general_ua'),
      value: this.settings.saved.userAgent === '' ? $r('app.string.general_default') : this.settings.saved.userAgent,
      onTap: (): void => this.openEditor('userAgent') })
    this.Rule()
    ListRow({ title: $r('app.string.general_hosts'),
      value: this.hostCount(), onTap: (): void => this.openEditor('hosts') })
    this.Rule()
    GeneralSwitchRow({ label: $r('app.string.general_auto_check_update'),
      checked: this.updates.automatic, interactive: this.updates.preferenceReady && !this.updates.preferenceSaving,
      onToggle: (isOn: boolean): void => {
        this.updates.setAutomatic(this.context(), isOn).catch((): void => {
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.general_save_failed') });
        });
      } })
  }

  @Builder
  Diagnostics() {
    ListRow({ title: $r('app.string.general_log_level'), value: logLevelLabel(this.settings.saved.logLevel),
      onTap: (): void => this.openEditor('level') })
    this.Rule()
    GeneralSwitchRow({ label: $r('app.string.general_capture_logs'), checked: this.settings.saved.captureLogs,
      interactive: !this.isSaving, onToggle: (isOn: boolean): void => this.setSwitch('capture', isOn) })
  }

  @Builder
  PortInputs() {
    ForEach(PORT_LABELS, (label: string, index: number): void => {
      Row({ space: 12 }) {
        Text(label).fontSize(16).layoutWeight(1)
        TextInput({ text: this.editedPorts[index] }).width(126).type(InputType.Number).maxLength(5)
          .accessibilityText(label).onChange((text: string): void => { this.editedPorts[index] = text; })
      }.width('100%')
    }, (label: string): string => label)
    Text($r('app.string.general_ports_hint')).fontSize(13).fontColor($r('sys.color.font_secondary'))
    if (this.settings.saved.ports !== undefined) {
      Button($r('app.string.general_inherit')).buttonStyle(ButtonStyleMode.TEXTUAL)
        .enabled(!this.isSaving).onClick((): void => this.saveEditor(true))
    }
  }

  @Builder
  AuthInputs() {
    GeneralSwitchRow({ label: $r('app.string.general_auth'), checked: this.authEnabled, interactive: !this.isSaving,
      onToggle: (isOn: boolean): void => {
        this.authEnabled = isOn;
        if (isOn && this.username === '') { this.username = generatedCredential(8); }
        if (isOn && this.password === '') { this.password = generatedCredential(16); }
      } })
    if (this.authEnabled) {
      TextInput({ text: this.username, placeholder: $r('app.string.local_proxy_field_username') }).maxLength(128)
        .onChange((text: string): void => { this.username = text; })
      TextInput({ text: this.password, placeholder: $r('app.string.local_proxy_field_password') })
        .type(InputType.Password).maxLength(512).onChange((text: string): void => { this.password = text; })
    }
  }

  @Builder
  ControllerInputs() {
    GeneralSwitchRow({ label: $r('app.string.general_controller'), checked: this.panelEnabled, interactive: !this.isSaving,
      onToggle: (isOn: boolean): void => {
        this.panelEnabled = isOn;
        if (isOn && this.editorText === '') { this.editorText = generatedCredential(32); }
      } })
    if (this.panelEnabled) {
      Text('127.0.0.1:9090').fontSize(14).fontColor($r('sys.color.font_secondary'))
      TextInput({ text: this.editorText, placeholder: $r('app.string.general_controller_secret') })
        .type(InputType.Password).maxLength(512).onChange((text: string): void => { this.editorText = text; })
      Button($r('app.string.general_new_secret')).buttonStyle(ButtonStyleMode.TEXTUAL)
        .onClick((): void => { this.editorText = generatedCredential(32); })
    }
  }

  @Builder
  Choices() {
    if (this.editor === 'level') {
      ForEach(GENERAL_LEVELS, (level: string): void => {
        ListRow({ title: logLevelLabel(level), chevron: false,
          trailingIcon: level === this.settings.saved.logLevel ? $r('sys.symbol.checkmark') : undefined,
          onTap: (): void => this.selectLevel(level) })
      }, (level: string): string => level)
    } else {
      ForEach(GENERAL_TIMEOUTS, (ms: number): void => {
        ListRow({ title: $r('app.string.proxy_delay_ms', ms), chevron: false,
          trailingIcon: ms === this.settings.saved.delayTimeout ? $r('sys.symbol.checkmark') : undefined,
          onTap: (): void => this.selectTimeout(ms) })
      }, (ms: number): string => ms.toString())
    }
  }

  @Builder
  EditorSheet() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.editor === 'level' || this.editor === 'timeout') {
          this.Choices()
        } else if (this.editor === 'ports') {
          this.PortInputs()
        } else if (this.editor === 'authentication') {
          this.AuthInputs()
        } else if (this.editor === 'controller') {
          this.ControllerInputs()
        } else if (this.editor === 'userAgent') {
          TextInput({ text: this.editorText, placeholder: 'ArkClash clash.meta' }).maxLength(512)
            .onChange((text: string): void => { this.editorText = text; })
          Text($r('app.string.general_ua_hint')).fontSize(13).fontColor($r('sys.color.font_secondary'))
        } else {
          TextArea({ text: this.editorText, placeholder: 'example.com 192.0.2.1' }).height(160)
            .maxLength(32768).onChange((text: string): void => { this.editorText = text; })
          Text($r('app.string.general_hosts_hint')).fontSize(13).fontColor($r('sys.color.font_secondary'))
        }
        if (this.editorError !== '') {
          Text(this.editorError).fontSize(13).fontColor($r('app.color.status_error'))
        }
        if (this.editor !== 'level' && this.editor !== 'timeout') {
          Button($r('app.string.action_save')).id('general-editor-save').width('100%').height(48)
            .enabled(!this.isSaving).onClick((): void => this.saveEditor())
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
        .enabled(!this.isSaving)
    }.width('100%').height('100%').align(Alignment.Top)
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: 16 }) {
          if (this.loadFailed) {
            Button($r('app.string.action_retry')).onClick((): void => { this.load(); })
          } else if (!this.settings.loaded) {
            LoadingProgress().width(32).height(32)
          } else {
            SettingsSection({ heading: $r('app.string.general_inbound_section'), rows: (): void => this.Inbounds() })
            SettingsSection({ heading: $r('app.string.tools_connections'), rows: (): void => this.Connections() })
            SettingsSection({ heading: $r('app.string.general_core_section'), rows: (): void => this.Requests() })
            SettingsSection({ heading: $r('app.string.tools_logs'), rows: (): void => this.Diagnostics() })
          }
        }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
          .enabled(!this.isSaving)
      }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
        .bindSheet($$this.editing, this.EditorSheet, {
          title: { title: this.editorTitle() }, detents: [SheetSize.MEDIUM, SheetSize.LARGE],
          systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
          onWillDismiss: (action: DismissSheetAction): void => {
            if (!this.isSaving) { action.dismiss(); this.closeEditor(); }
          }
        })
    }
    .title(this.Header, { systemMaterial: this.appStyle.regularMaterial() })
    .backgroundColor(this.appStyle.palette.pageBackground)
  }
}

@ComponentV2
struct GeneralSwitchRow {
  @Param @Require label: Resource;
  @Param checked: boolean = false;
  @Param interactive: boolean = true;
  @Event onToggle: (isOn: boolean) => void = () => {};
  @Local private appStyle: AppearanceState = appAppearance;

  build() {
    Row() {
      Text(this.label).fontFamily(this.appStyle.fontFamily).fontSize(16).layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.checked }).accessibilityText(this.label)
        .selectedColor(this.appStyle.palette.brand).enabled(this.interactive)
        .onChange((isOn: boolean): void => { this.onToggle(isOn); })
    }.constraintSize({ minHeight: 56 }).padding({ left: 16, right: 16 }).width('100%')
  }
}
