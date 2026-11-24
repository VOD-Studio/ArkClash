import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AppUpdateState, appUpdateState } from '../../client/AppUpdate';
import { getAllowLan } from '../../client/Controller';
import { GeneralSettingsState, generalSettingsState } from '../../client/GeneralSettings';
import { Connection, connection } from '../../client/Connection';
import { appAppearance, AppearanceState } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { ListRow } from '../../components/ListRow';
import { uiResourceText } from '../../components/ResourceText';
import { PAGE_GUTTER } from '../../components/Theme';
import {
  compactGeneralCoreOverrides, DEFAULT_GENERAL_TEST_URL, defaultGeneralPorts, GeneralCoreOverrides,
  GeneralGeodataLoader, GeneralPorts, GeneralSettings, GENERAL_GEODATA_LOADERS, GENERAL_LEVELS, GENERAL_TIMEOUTS,
  GENERAL_USER_AGENT_LIMIT, validGeneralTestUrl, validGeneralUserAgent
} from '../../shared/GeneralSettings';
import { SettingsSection } from './SettingsSection';
import { logLevelLabel } from './LogLabels';

type GeneralEditor =
  'ports' | 'authentication' | 'controller' | 'userAgent' | 'hosts' | 'level' | 'timeout' | 'testUrl' | 'geodataLoader';
type GeneralToggle = 'capture' | 'closeConnections' | 'appendSystemDns';
type CoreOverrideKey = 'testUrl' | 'unifiedDelay' | 'tcpConcurrent' | 'ipv6' | 'geodataLoader';

const PORT_LABELS: string[] = ['Mixed', 'HTTP', 'SOCKS', 'Redir', 'TProxy'];
const CORE_OVERRIDE_KEYS: CoreOverrideKey[] = ['testUrl', 'unifiedDelay', 'tcpConcurrent', 'ipv6', 'geodataLoader'];

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

function cloneCoreOverrides(source: GeneralCoreOverrides | undefined): GeneralCoreOverrides {
  const copy: GeneralCoreOverrides = {};
  if (source === undefined) {
    return copy;
  }
  if (source.testUrl !== undefined) { copy.testUrl = source.testUrl; }
  if (source.unifiedDelay !== undefined) { copy.unifiedDelay = source.unifiedDelay; }
  if (source.tcpConcurrent !== undefined) { copy.tcpConcurrent = source.tcpConcurrent; }
  if (source.ipv6 !== undefined) { copy.ipv6 = source.ipv6; }
  if (source.geodataLoader !== undefined) { copy.geodataLoader = source.geodataLoader; }
  return copy;
}

function geodataLoaderLabel(loader: string): Resource {
  return loader === 'standard' ? $r('app.string.general_core_geodata_standard') :
    $r('app.string.general_core_geodata_memconservative');
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
  @Local private corePickerOpen: boolean = false;
  @Local private editedPorts: string[] = formatPorts(defaultGeneralPorts());
  @Local private authEnabled: boolean = false;
  @Local private username: string = '';
  @Local private password: string = '';
  @Local private panelEnabled: boolean = false;
  @Local private editorText: string = '';
  @Local private editorError: ResourceStr = '';
  @Local private userAgents: string[] = [];
  @Local private activeAgent: string = '';
  @Local private agentEditorOpen: boolean = false;
  @Local private editedAgent: string = '';
  @Local private effectiveAllowLan: boolean = false;
  @Local private allowLanSaving: boolean = false;
  private editorRevision: string = '';
  private pendingCoreEditor?: 'testUrl' | 'geodataLoader';
  private allowLanGeneration: number = 0;
  private mounted: boolean = false;

  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }

  aboutToAppear(): void {
    this.mounted = true;
    this.load();
    this.syncAllowLan();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.allowLanGeneration++;
  }

  @Monitor('conn.coreReady', 'conn.configRevision', 'conn.allowLan')
  syncAllowLan(): void {
    const generation = ++this.allowLanGeneration;
    if (this.conn.allowLan !== undefined) {
      this.effectiveAllowLan = this.conn.allowLan;
      return;
    }
    if (!this.conn.coreReady) {
      this.effectiveAllowLan = false;
      return;
    }
    getAllowLan(this.context().filesDir).then((allow: boolean): void => {
      if (this.mounted && generation === this.allowLanGeneration && this.conn.allowLan === undefined) {
        this.effectiveAllowLan = allow;
      }
    }).catch((): void => {});
  }

  private desiredAllowLan(): boolean {
    return this.conn.allowLan ?? this.effectiveAllowLan;
  }

  private async toggleAllowLan(isOn: boolean): Promise<void> {
    if (this.allowLanSaving || isOn === this.desiredAllowLan()) {
      return;
    }
    const previous = this.effectiveAllowLan;
    this.allowLanSaving = true;
    this.effectiveAllowLan = isOn;
    try {
      await this.conn.changeAllowLan(isOn);
      if (this.conn.coreReady) {
        const effective = await getAllowLan(this.context().filesDir);
        this.effectiveAllowLan = effective;
        if (effective !== isOn) {
          throw new Error('allow_lan_not_applied');
        }
      }
      if (this.mounted) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.general_saved') });
      }
    } catch (_error) {
      this.effectiveAllowLan = previous;
      if (this.mounted) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.dash_lan_failed') });
      }
    } finally {
      this.allowLanSaving = false;
    }
  }

  private async load(): Promise<void> {
    try {
      await this.settings.load(this.context());
      this.loadFailed = false;
    } catch (_error) { this.loadFailed = true; }
  }

  private draft(): GeneralSettings {
    const saved = this.settings.saved;
    const overrides = compactGeneralCoreOverrides(cloneCoreOverrides(saved.coreOverrides));
    return {
      revision: saved.revision, ports: saved.ports, authentication: saved.authentication,
      controllerSecret: saved.controllerSecret, userAgent: saved.userAgent, userAgents: saved.userAgents,
      appendSystemDns: saved.appendSystemDns, hosts: saved.hosts,
      delayTimeout: saved.delayTimeout, closeConnections: saved.closeConnections, logLevel: saved.logLevel,
      captureLogs: saved.captureLogs, coreOverrides: overrides
    };
  }

  private hasCoreOverride(key: CoreOverrideKey): boolean {
    const overrides = this.settings.saved.coreOverrides;
    if (overrides === undefined) {
      return false;
    }
    switch (key) {
      case 'testUrl': return overrides.testUrl !== undefined;
      case 'unifiedDelay': return overrides.unifiedDelay !== undefined;
      case 'tcpConcurrent': return overrides.tcpConcurrent !== undefined;
      case 'ipv6': return overrides.ipv6 !== undefined;
      case 'geodataLoader': return overrides.geodataLoader !== undefined;
    }
  }

  private addedCoreOverrides(): CoreOverrideKey[] {
    return CORE_OVERRIDE_KEYS.filter((key: CoreOverrideKey): boolean => this.hasCoreOverride(key));
  }

  private availableCoreOverrides(): CoreOverrideKey[] {
    return CORE_OVERRIDE_KEYS.filter((key: CoreOverrideKey): boolean => !this.hasCoreOverride(key));
  }

  private coreOverrideLabel(key: CoreOverrideKey): Resource {
    switch (key) {
      case 'testUrl': return $r('app.string.general_core_test_url');
      case 'unifiedDelay': return $r('app.string.general_core_unified_delay');
      case 'tcpConcurrent': return $r('app.string.general_core_tcp_concurrent');
      case 'ipv6': return $r('app.string.general_core_ipv6');
      case 'geodataLoader': return $r('app.string.general_core_geodata_loader');
    }
  }

  private coreOverrideChecked(key: CoreOverrideKey): boolean {
    const overrides = this.settings.saved.coreOverrides;
    switch (key) {
      case 'unifiedDelay': return overrides?.unifiedDelay === true;
      case 'tcpConcurrent': return overrides?.tcpConcurrent === true;
      case 'ipv6': return overrides?.ipv6 === true;
      default: return false;
    }
  }

  private coreSectionFooter(): ResourceStr {
    if (this.hasCoreOverride('ipv6')) {
      return `${uiResourceText(this.getUIContext(), $r('app.string.general_core_override_desc'))}\n` +
        uiResourceText(this.getUIContext(), $r('app.string.general_core_ipv6_hint'));
    }
    return $r('app.string.general_core_override_desc');
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
      if (this.availableCoreOverrides().length === 0) {
        this.corePickerOpen = false;
      }
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
        this.activeAgent = saved.userAgent;
        this.userAgents = Array.from(new Set<string>((saved.userAgents ?? []).concat(
          saved.userAgent === '' ? [] : [saved.userAgent])));
        break;
      case 'hosts':
        const hosts = saved.hosts;
        this.editorText = hosts === null ? '' :
          Object.keys(hosts).map((domain: string): string => `${domain} ${hosts[domain].join(' ')}`).join('\n');
        break;
      case 'testUrl':
        this.editorText = saved.coreOverrides?.testUrl ?? DEFAULT_GENERAL_TEST_URL;
        break;
      case 'geodataLoader':
        this.editorText = saved.coreOverrides?.geodataLoader ?? 'memconservative';
        break;
    }
    this.editing = true;
  }

  private closeEditor(): void {
    this.editing = false;
    this.password = '';
    this.username = '';
    this.editorText = '';
    this.agentEditorOpen = false;
  }

  private addCoreOverride(key: CoreOverrideKey): void {
    if (key === 'testUrl' || key === 'geodataLoader') {
      // 下一层编辑 Sheet 需等当前选择 Sheet 消失后再打开（docs/agents/ui.md）。
      this.pendingCoreEditor = key;
      this.corePickerOpen = false;
      return;
    }
    const draft = this.draft();
    const overrides = cloneCoreOverrides(draft.coreOverrides);
    switch (key) {
      case 'unifiedDelay': overrides.unifiedDelay = true; break;
      case 'tcpConcurrent': overrides.tcpConcurrent = true; break;
      case 'ipv6': overrides.ipv6 = false; break;
    }
    draft.coreOverrides = compactGeneralCoreOverrides(overrides);
    this.save(draft);
  }

  private openPendingCoreEditor(): void {
    const pending = this.pendingCoreEditor;
    this.pendingCoreEditor = undefined;
    if (pending !== undefined && this.mounted) {
      this.openEditor(pending);
    }
  }

  private removeCoreOverride(key: CoreOverrideKey): void {
    const draft = this.draft();
    const overrides = cloneCoreOverrides(draft.coreOverrides);
    switch (key) {
      case 'testUrl': overrides.testUrl = undefined; break;
      case 'unifiedDelay': overrides.unifiedDelay = undefined; break;
      case 'tcpConcurrent': overrides.tcpConcurrent = undefined; break;
      case 'ipv6': overrides.ipv6 = undefined; break;
      case 'geodataLoader': overrides.geodataLoader = undefined; break;
    }
    draft.coreOverrides = compactGeneralCoreOverrides(overrides);
    this.save(draft);
  }

  private setCoreToggle(key: CoreOverrideKey, isOn: boolean): void {
    if (!this.hasCoreOverride(key) || this.coreOverrideChecked(key) === isOn) {
      return;
    }
    const draft = this.draft();
    const overrides = cloneCoreOverrides(draft.coreOverrides);
    switch (key) {
      case 'unifiedDelay': overrides.unifiedDelay = isOn; break;
      case 'tcpConcurrent': overrides.tcpConcurrent = isOn; break;
      case 'ipv6': overrides.ipv6 = isOn; break;
    }
    draft.coreOverrides = compactGeneralCoreOverrides(overrides);
    this.save(draft);
  }

  private selectGeodataLoader(loader: GeneralGeodataLoader): void {
    const draft = this.draft();
    draft.revision = this.editorRevision;
    if (draft.coreOverrides?.geodataLoader === loader) {
      this.closeEditor();
      return;
    }
    const overrides = cloneCoreOverrides(draft.coreOverrides);
    overrides.geodataLoader = loader;
    draft.coreOverrides = compactGeneralCoreOverrides(overrides);
    this.save(draft, true);
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
          draft.userAgent = this.activeAgent;
          draft.userAgents = this.userAgents;
          break;
        case 'hosts':
          const hosts = parseHostRows(this.editorText);
          draft.hosts = Object.keys(hosts).length > 0 ? hosts : null;
          break;
        case 'testUrl':
          const target = this.editorText.trim();
          if (!validGeneralTestUrl(target)) { throw new Error('general_settings_invalid'); }
          const overrides = cloneCoreOverrides(draft.coreOverrides);
          overrides.testUrl = target;
          draft.coreOverrides = compactGeneralCoreOverrides(overrides);
          break;
      }
      this.save(draft, true);
    } catch (error) {
      this.editorError = this.errorLabel(error as Error);
    }
  }

  private editAgent(agent: string): void {
    this.editedAgent = agent;
    this.editorText = agent;
    this.editorError = '';
    this.agentEditorOpen = true;
  }

  private closeAgentEditor(): void {
    this.agentEditorOpen = false;
    this.editorError = '';
  }

  private applyAgent(): void {
    const next = this.editorText.trim();
    if (next === '' || !validGeneralUserAgent(next) ||
      (next !== this.editedAgent && this.userAgents.includes(next))) {
      this.editorError = $r('app.string.general_ua_preset_invalid');
      return;
    }
    this.userAgents = this.editedAgent === '' ? this.userAgents.concat(next) :
      this.userAgents.map((agent: string): string => agent === this.editedAgent ? next : agent);
    if (this.editedAgent !== '' && this.activeAgent === this.editedAgent) { this.activeAgent = next; }
    this.closeAgentEditor();
  }

  private deleteAgent(): void {
    this.userAgents = this.userAgents.filter((agent: string): boolean => agent !== this.editedAgent);
    if (this.activeAgent === this.editedAgent) { this.activeAgent = ''; }
    this.closeAgentEditor();
  }

  private setSwitch(kind: GeneralToggle, isOn: boolean): void {
    const draft = this.draft();
    switch (kind) {
      case 'capture':
        if (draft.captureLogs === isOn) { return; }
        draft.captureLogs = isOn;
        break;
      case 'closeConnections':
        if ((draft.closeConnections ?? true) === isOn) { return; }
        draft.closeConnections = isOn;
        break;
      case 'appendSystemDns':
        if ((draft.appendSystemDns ?? false) === isOn) { return; }
        draft.appendSystemDns = isOn;
        break;
    }
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
      case 'testUrl': return $r('app.string.general_core_test_url');
      case 'geodataLoader': return $r('app.string.general_core_geodata_loader');
    }
  }

  @Builder
  Header() { DestinationTitle({ titleText: $r('app.string.tools_general') }) }

  @Builder
  Rule(left: number = 16) { Divider().color(this.appStyle.palette.divider).margin({ left: left, right: 16 }) }

  @Builder
  Inbounds() {
    ListRow({ title: $r('app.string.general_ports'),
      value: this.settings.saved.ports === undefined ? $r('app.string.general_inherit') :
        this.settings.saved.ports.mixed.toString(), onTap: (): void => this.openEditor('ports') })
    this.Rule()
    GeneralSwitchRow({ label: $r('app.string.lan_proxy'),
      checked: this.desiredAllowLan(), interactive: !this.allowLanSaving,
      onToggle: (isOn: boolean): void => { this.toggleAllowLan(isOn); } })
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
  CoreOverrideRow(key: CoreOverrideKey) {
    Row() {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.minus')).fontSize(16).fontColor([$r('app.color.status_error')])
      }
      .width(40)
      .height(40)
      .buttonStyle(ButtonStyleMode.NORMAL)
      .accessibilityText($r('app.string.general_core_override_remove'))
      .enabled(!this.isSaving)
      .onClick((): void => this.removeCoreOverride(key))
      if (key === 'testUrl') {
        ListRow({ title: this.coreOverrideLabel(key),
          value: this.settings.saved.coreOverrides?.testUrl ?? DEFAULT_GENERAL_TEST_URL,
          onTap: (): void => this.openEditor('testUrl') })
          .layoutWeight(1)
          .enabled(!this.isSaving)
      } else if (key === 'geodataLoader') {
        ListRow({ title: this.coreOverrideLabel(key),
          value: geodataLoaderLabel(this.settings.saved.coreOverrides?.geodataLoader ?? 'memconservative'),
          onTap: (): void => this.openEditor('geodataLoader') })
          .layoutWeight(1)
          .enabled(!this.isSaving)
      } else {
        Text(this.coreOverrideLabel(key))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .padding({ left: 12 })
        Toggle({ type: ToggleType.Switch, isOn: this.coreOverrideChecked(key) })
          .accessibilityText(uiResourceText(this.getUIContext(), this.coreOverrideLabel(key)))
          .selectedColor(this.appStyle.palette.brand)
          .enabled(!this.isSaving)
          .onChange((isOn: boolean): void => this.setCoreToggle(key, isOn))
          .margin({ right: 16 })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 8 })
  }

  @Builder
  Requests() {
    ListRow({ title: $r('app.string.general_ua'),
      value: this.settings.saved.userAgent === '' ? $r('app.string.general_default') : this.settings.saved.userAgent,
      onTap: (): void => this.openEditor('userAgent') })
    this.Rule()
    GeneralSwitchRow({ label: $r('app.string.general_auto_check_update'),
      checked: this.updates.automatic, interactive: this.updates.preferenceReady && !this.updates.preferenceSaving,
      onToggle: (isOn: boolean): void => {
        this.updates.setAutomatic(this.context(), isOn).catch((): void => {
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.general_save_failed') });
        });
      } })
    this.Rule()
    ListRow({ title: $r('app.string.general_hosts'),
      value: this.hostCount(), onTap: (): void => this.openEditor('hosts') })
    this.Rule()
    GeneralSwitchRow({ label: $r('app.string.general_append_system_dns'),
      checked: this.settings.saved.appendSystemDns ?? false, interactive: !this.isSaving,
      onToggle: (isOn: boolean): void => this.setSwitch('appendSystemDns', isOn) })
    ForEach(this.addedCoreOverrides(), (key: CoreOverrideKey): void => {
      this.Rule()
      this.CoreOverrideRow(key)
    }, (key: CoreOverrideKey): string => key)
    if (this.availableCoreOverrides().length > 0) {
      this.Rule()
      Row({ space: 12 }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(16).fontColor([this.appStyle.palette.brand])
        }
        .width(28)
        .height(28)
        .borderRadius(14)
        .backgroundColor(this.appStyle.palette.brandSoft)
        Text($r('app.string.general_core_override_add'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontColor(this.appStyle.palette.brand)
          .layoutWeight(1)
      }
      .width('100%')
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .stateStyles({
        pressed: { .backgroundColor($r('sys.color.interactive_pressed')) },
        normal: { .backgroundColor(Color.Transparent) }
      })
      .enabled(!this.isSaving)
      .onClick((): void => { this.corePickerOpen = true; })
    }
  }

  @Builder
  CoreOverridePickerRows() {
    ForEach(this.availableCoreOverrides(), (key: CoreOverrideKey): void => {
      if (this.availableCoreOverrides()[0] !== key) {
        this.Rule()
      }
      ListRow({ title: this.coreOverrideLabel(key), chevron: key === 'testUrl' || key === 'geodataLoader',
        onTap: (): void => this.addCoreOverride(key) })
        .enabled(!this.isSaving)
    }, (key: CoreOverrideKey): string => key)
  }

  @Builder
  CoreOverridePicker() {
    Scroll() {
      Column({ space: 16 }) {
        SettingsSection({
          footer: this.availableCoreOverrides().includes('ipv6') ? $r('app.string.general_core_ipv6_hint') : '',
          rows: (): void => this.CoreOverridePickerRows()
        })
      }
      .width('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
    }
    .width('100%')
    .align(Alignment.Top)
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
    } else if (this.editor === 'geodataLoader') {
      ForEach(GENERAL_GEODATA_LOADERS, (loader: string): void => {
        ListRow({ title: geodataLoaderLabel(loader), chevron: false,
          trailingIcon: loader === this.editorText ? $r('sys.symbol.checkmark') : undefined,
          onTap: (): void => this.selectGeodataLoader(loader as GeneralGeodataLoader) })
      }, (loader: string): string => loader)
    } else {
      ForEach(GENERAL_TIMEOUTS, (ms: number): void => {
        ListRow({ title: $r('app.string.proxy_delay_ms', ms), chevron: false,
          trailingIcon: ms === this.settings.saved.delayTimeout ? $r('sys.symbol.checkmark') : undefined,
          onTap: (): void => this.selectTimeout(ms) })
      }, (ms: number): string => ms.toString())
    }
  }

  @Builder
  UserAgentEditor() {
    if (this.agentEditorOpen) {
      TextInput({ text: this.editorText, placeholder: 'ArkClash clash.meta' }).maxLength(512)
        .accessibilityText($r('app.string.general_ua'))
        .onChange((text: string): void => { this.editorText = text; })
      Row({ space: 8 }) {
        Button($r('app.string.action_cancel')).buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick((): void => this.closeAgentEditor())
        if (this.editedAgent !== '') {
          Button($r('app.string.action_delete'), { role: ButtonRole.ERROR }).buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => this.deleteAgent())
        }
        Button($r('app.string.dash_done')).onClick((): void => this.applyAgent())
      }.width('100%').justifyContent(FlexAlign.End)
    } else {
      ListRow({ title: $r('app.string.general_default'), chevron: false,
        trailingIcon: this.activeAgent === '' ? $r('sys.symbol.checkmark') : undefined,
        onTap: (): void => { this.activeAgent = ''; } })
      ForEach(this.userAgents, (agent: string): void => {
        Row({ space: 8 }) {
          Row() {
            ListRow({ title: agent, chevron: false,
              trailingIcon: this.activeAgent === agent ? $r('sys.symbol.checkmark') : undefined,
              onTap: (): void => { this.activeAgent = agent; } })
          }.layoutWeight(1)
          Button($r('app.string.action_edit')).buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => this.editAgent(agent))
        }.width('100%')
      }, (agent: string): string => agent)
      Button($r('app.string.action_add')).buttonStyle(ButtonStyleMode.TEXTUAL)
        .enabled(this.userAgents.length < GENERAL_USER_AGENT_LIMIT)
        .onClick((): void => this.editAgent(''))
    }
  }

  @Builder
  EditorSheet() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.editor === 'level' || this.editor === 'timeout' || this.editor === 'geodataLoader') {
          this.Choices()
        } else if (this.editor === 'ports') {
          this.PortInputs()
        } else if (this.editor === 'authentication') {
          this.AuthInputs()
        } else if (this.editor === 'controller') {
          this.ControllerInputs()
        } else if (this.editor === 'userAgent') {
          this.UserAgentEditor()
        } else if (this.editor === 'testUrl') {
          TextInput({ text: this.editorText, placeholder: DEFAULT_GENERAL_TEST_URL }).maxLength(2048)
            .accessibilityText($r('app.string.general_core_test_url'))
            .onChange((text: string): void => { this.editorText = text; this.editorError = ''; })
          Text($r('app.string.general_core_test_url_hint')).fontSize(13).fontColor($r('sys.color.font_secondary'))
        } else {
          TextArea({ text: this.editorText, placeholder: 'example.com 192.0.2.1' }).height(160)
            .maxLength(32768).onChange((text: string): void => { this.editorText = text; })
          Text($r('app.string.general_hosts_hint')).fontSize(13).fontColor($r('sys.color.font_secondary'))
        }
        if (this.editorError !== '') {
          Text(this.editorError).fontSize(13).fontColor($r('app.color.status_error'))
        }
        if (this.editor !== 'level' && this.editor !== 'timeout' && this.editor !== 'geodataLoader' &&
          !this.agentEditorOpen) {
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
      Stack() {
        Scroll() {
          Column({ space: 16 }) {
            if (this.loadFailed) {
              Button($r('app.string.action_retry')).onClick((): void => { this.load(); })
            } else if (!this.settings.loaded) {
              LoadingProgress().width(32).height(32)
            } else {
              SettingsSection({ heading: $r('app.string.general_inbound_section'), rows: (): void => this.Inbounds() })
              SettingsSection({ heading: $r('app.string.tools_connections'), rows: (): void => this.Connections() })
              SettingsSection({ heading: $r('app.string.general_core_section'), footer: this.coreSectionFooter(),
                rows: (): void => this.Requests() })
              SettingsSection({ heading: $r('app.string.tools_logs'), rows: (): void => this.Diagnostics() })
            }
          }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
            .enabled(!this.isSaving)
        }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Off)
        Column()
          .bindSheet($$this.corePickerOpen, this.CoreOverridePicker, {
            title: { title: $r('app.string.general_core_override_add') }, height: SheetSize.MEDIUM,
            preferType: SheetType.BOTTOM, showClose: true, systemMaterial: this.appStyle.sheetMaterial(),
            onWillDismiss: (action: DismissSheetAction): void => { if (!this.isSaving) { action.dismiss(); } },
            onDisappear: (): void => this.openPendingCoreEditor()
          })
        Column()
          .bindSheet($$this.editing, this.EditorSheet, {
            title: { title: this.editorTitle() }, detents: [SheetSize.MEDIUM, SheetSize.LARGE],
            systemMaterial: this.appStyle.sheetMaterial(), showClose: true,
            onWillDismiss: (action: DismissSheetAction): void => {
              if (!this.isSaving) { action.dismiss(); this.closeEditor(); }
            }
          })
      }.width('100%').height('100%')
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
