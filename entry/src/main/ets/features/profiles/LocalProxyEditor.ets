import { common } from '@kit.AbilityKit';
import { decodeProxyLinks, encodeProxyLinks, validateProxyDefinitions } from '../../client/LocalProxyCore';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { ListRow } from '../../components/ListRow';
import { uiResourceText } from '../../components/ResourceText';
import { CARD_RADIUS, HEADER_ACTION, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { checkProxyName, emptyLocalProxies, LOCAL_PROXY_LIMIT, LocalProxy, LocalProxySnapshot,
  localProxyName, localProxyProblem, mergeProxyLink, nameProxyFromLink } from '../../shared/profiles/LocalProxies';
import { changeProxyOption, changeProxyType, parseProxyMap, PROXY_CREDENTIAL_FIELDS, PROXY_FIELDS, PROXY_TYPES,
  ProxyDefinition, ProxyField, proxyChoices, proxyFieldHasValue, proxyList, proxyMapText, proxyOptions, proxyText, proxyValue,
  REQUIRED_PROXY_KEYS } from '../../shared/profiles/LocalProxySchema';
import { commitLocalProxies, saveLocalProxy } from '../../shared/profiles/LocalProxyStore';
import { proxyFieldTitle, proxyIssue } from './LocalProxyLabels';

const PROTOCOL_OPTIONS: SelectOption[] = PROXY_TYPES.map((type: string): SelectOption => ({ value: type }));
const OPTION_SECTIONS = ['authentication', 'transport', 'tls', 'connection', 'other'];

function optionSection(section: string): ResourceStr {
  switch (section) {
    case 'authentication': return $r('app.string.local_proxy_auth');
    case 'transport': return $r('app.string.local_proxy_transport');
    case 'tls': return 'TLS';
    case 'connection': return $r('app.string.local_proxy_connection');
    default: return $r('app.string.local_proxy_other');
  }
}

function fieldLimit(field: ProxyField): number {
  if (field.id === 'name' || field.id === 'networkName' || field.id === 'interfaceName') { return 255; }
  if (field.id === 'port') { return 5; }
  if (field.id === 'openVpnCa') { return 32000; }
  if (field.kind === 'number') { return 10; }
  return field.kind === 'secret' || field.id.toLowerCase().includes('path') ? 2048 : 512;
}

@ComponentV2
struct ProxyFormSection {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param heading: ResourceStr = '';
  @BuilderParam content: () => void = this.Empty;

  @Builder
  Empty() {}

  build() {
    Column({ space: 8 }) {
      Text(this.heading).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_secondary'))
        .padding({ left: 16, right: 16 })
      Column() { this.content() }.width('100%').borderRadius(CARD_RADIUS)
        .clip(true).backgroundColor(this.appStyle.palette.cardBackground)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct LocalProxyEditor {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param proxy: LocalProxy | undefined = undefined;
  @Param snapshot: LocalProxySnapshot = emptyLocalProxies();
  @Param foreground: boolean = true;
  @Param dismissRequest: number = 0;
  @Event onClose: () => void = () => {};
  @Event onSaved: (snapshot: LocalProxySnapshot, message: ResourceStr) => void =
    (_snapshot: LocalProxySnapshot, _message: ResourceStr): void => {};
  @Local private definition: ProxyDefinition = { 'type': 'ss' };
  @Local private shownOptions: ProxyField[] = [];
  @Local private available: ProxyField[] = [];
  @Local private groups: string[] = [];
  @Local private basic: ProxyField[] = [];
  @Local private authentication: ProxyField[] = [];
  @Local private network: ProxyField[] = [];
  @Local private emptyOptions: string[] = [];
  @Local private dirty: boolean = false;
  @Local private busy: boolean = false;
  @Local private submitted: boolean = false;
  @Local private issue: string = '';
  @Local private checking: boolean = false;
  @Local private optionsShown: boolean = false;
  @Local private valuesShown: boolean = false;
  @Local private valuesField: ProxyField | undefined = undefined;
  @Local private valuesText: string = '';
  @Local private valuesError: ResourceStr = '';
  @Local private valuesDiscard: boolean = false;
  @Local private originalValues: string = '';
  @Local private decision: string = '';
  @Local private linksShown: boolean = false;
  @Local private linkError: ResourceStr = '';
  @Local private linkText: string = '';
  @Local private linkDiscard: boolean = false;
  private originalLink: string = '';
  private original: ProxyDefinition = { 'type': 'ss' };
  private originalEmpty: string[] = [];
  private base: LocalProxySnapshot = emptyLocalProxies();
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private shown: boolean = false;
  private timer: number = -1;
  private generation: number = 0;

  aboutToAppear(): void {
    this.shown = true;
    this.base = this.snapshot;
    this.original = this.proxy?.definition ?? { 'type': 'ss' };
    this.originalEmpty = this.proxy?.emptyOptions ?? [];
    this.definition = this.original;
    this.emptyOptions = this.originalEmpty.slice();
    this.updateSections(this.emptyOptions);
    this.schedule();
  }

  aboutToDisappear(): void {
    this.shown = false;
    this.stopValidation();
  }

  @Monitor('dismissRequest')
  dismissChanged(): void { this.requestClose(); }

  @Monitor('foreground')
  foregroundChanged(): void {
    if (this.foreground) { this.schedule(); }
    else { this.stopValidation(); }
  }

  private type(): string { return proxyText(this.definition, ['type']); }

  private problem(definition: ProxyDefinition): string {
    return localProxyProblem(definition) || checkProxyName(this.base, definition, this.proxy?.id ?? '');
  }

  private updateSections(shown: string[]): void {
    const type = this.type();
    const ids = ['name', 'server', 'port'].concat(PROXY_CREDENTIAL_FIELDS[type] ?? [], 'udp');
    const primary = ids.map((id: string): ProxyField | undefined => PROXY_FIELDS.find((field: ProxyField): boolean =>
      field.id === id)).filter((field: ProxyField | undefined): boolean => field !== undefined) as ProxyField[];
    this.basic = primary.filter((field: ProxyField): boolean => field.section !== 'authentication' &&
      field.section !== 'network' && !(type === 'easytier' && (field.id === 'server' || field.id === 'port')));
    this.authentication = primary.filter((field: ProxyField): boolean => field.section === 'authentication');
    this.network = primary.filter((field: ProxyField): boolean => field.section === 'network');
    const options = proxyOptions(this.definition);
    this.shownOptions = options.filter((field: ProxyField): boolean =>
      shown.includes(field.id) || proxyFieldHasValue(this.definition, field));
    this.available = options.filter((field: ProxyField): boolean => !this.shownOptions.includes(field));
    this.groups = OPTION_SECTIONS.filter((section: string): boolean => this.available.some((field: ProxyField): boolean =>
      field.section === section));
    this.emptyOptions = this.emptyOptions.filter((id: string): boolean => this.shownOptions.some((field: ProxyField): boolean =>
      field.id === id && !proxyFieldHasValue(this.definition, field)));
    this.dirty = JSON.stringify(this.definition) !== JSON.stringify(this.original) ||
      this.emptyOptions.join(',') !== this.originalEmpty.join(',');
  }

  private update(field: ProxyField, value: Object | undefined, remove: boolean = false): void {
    const before = proxyOptions(this.definition);
    const shown = this.shownOptions.map((option: ProxyField): string => option.id)
      .filter((id: string): boolean => !remove || id !== field.id);
    const nextValue = remove && field.kind === 'map' ? parseProxyMap(this.definition, field, '') : value;
    this.definition = changeProxyOption(this.definition, field, nextValue);
    const unlocked = proxyOptions(this.definition).filter((option: ProxyField): boolean => !before.includes(option))
      .map((option: ProxyField): string => option.id);
    this.emptyOptions = this.emptyOptions.filter((id: string): boolean => id !== field.id).concat(unlocked);
    this.updateSections(shown.concat(unlocked));
    this.schedule();
  }

  private changeType(type: string): void {
    const shown = this.shownOptions.map((field: ProxyField): string => field.id);
    this.definition = changeProxyType(this.definition, type);
    this.updateSections(shown);
    this.schedule();
  }

  private addOption(field: ProxyField): void {
    this.optionsShown = false;
    const initial = field.kind === 'choice' ? proxyChoices(this.type(), field.id)[0] :
      field.kind === 'toggle' ? true : undefined;
    this.shownOptions = this.shownOptions.concat(field);
    this.update(field, initial);
    if (initial === undefined) {
      this.emptyOptions = this.emptyOptions.concat(field.id);
      this.updateSections(this.shownOptions.map((option: ProxyField): string => option.id));
    }
  }

  private stopValidation(): void {
    clearTimeout(this.timer);
    this.generation++;
    this.checking = false;
  }

  private schedule(): void {
    this.stopValidation();
    this.issue = this.problem(this.definition);
    if (!this.foreground || !this.shown || this.issue !== '') { return; }
    const generation = this.generation;
    const definition = this.definition;
    this.timer = setTimeout((): void => { this.validate(definition, generation); }, 400);
  }

  private async validate(definition: ProxyDefinition, generation: number): Promise<void> {
    this.checking = true;
    let result = '';
    try {
      result = (await validateProxyDefinitions(this.context, [definition]))[0] ?? 'local_proxy_core_unavailable';
    } catch (error) {
      result = (error as Error).message;
    }
    if (this.shown && this.generation === generation) {
      this.issue = result;
      this.checking = false;
    }
  }

  private async save(): Promise<void> {
    if (this.busy) { return; }
    this.submitted = true;
    this.stopValidation();
    this.issue = this.problem(this.definition);
    if (this.issue !== '') { return; }
    this.busy = true;
    try {
      let validated = true;
      try {
        this.issue = (await validateProxyDefinitions(this.context, [this.definition]))[0] ??
          'local_proxy_core_unavailable';
      } catch (error) {
        this.issue = (error as Error).message;
      }
      if (this.issue === 'local_proxy_core_unavailable') { validated = false; }
      else if (this.issue !== '') { return; }
      const next = await saveLocalProxy(this.context.filesDir, this.base, this.proxy?.id ?? '',
        this.definition, this.emptyOptions);
      this.onSaved(next, validated ? $r('app.string.local_proxy_saved') : $r('app.string.local_proxy_saved_pending'));
    } catch (error) {
      this.issue = (error as Error).message;
    } finally { this.busy = false; }
  }

  private async remove(): Promise<void> {
    if (this.busy || this.proxy === undefined) { return; }
    this.busy = true;
    try {
      const id = this.proxy.id;
      const updated = await commitLocalProxies(this.context.filesDir, this.base,
        this.base.proxies.filter((item: LocalProxy): boolean => item.id !== id));
      this.onSaved(updated, $r('app.string.local_proxy_deleted'));
    } catch (error) {
      this.decision = '';
      this.issue = (error as Error).message;
      this.submitted = true;
    } finally { this.busy = false; }
  }

  private requestClose(): void {
    if (this.busy) { return; }
    if (this.decision !== '') { this.decision = ''; }
    else if (this.dirty) { this.decision = 'discard'; }
    else { this.onClose(); }
  }

  private async openLink(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    this.originalLink = '';
    try {
      if (proxyText(this.definition, ['server']) !== '') {
        this.originalLink = (await encodeProxyLinks(this.context, [this.definition], false))[0] ?? '';
      }
    } catch (error) {
      this.originalLink = '';
    } finally { this.busy = false; }
    if (!this.shown) { return; }
    this.linkText = this.originalLink;
    this.linkError = '';
    this.linkDiscard = false;
    this.linksShown = true;
  }

  private async readLink(): Promise<void> {
    if (this.busy) { return; }
    const link = this.linkText.trim();
    if (link === this.originalLink) { this.linksShown = false; return; }
    if (link === '' || link.includes('\n')) {
      this.linkError = proxyIssue('local_proxy_single_link');
      return;
    }
    this.busy = true;
    try {
      const decoded = await decodeProxyLinks(this.context, [link]);
      if (!decoded[0]?.length) { throw new Error('local_proxy_link'); }
      if (decoded[0].length !== 1) { throw new Error('local_proxy_single_link'); }
      const old = this.originalLink === '' ? [] : await decodeProxyLinks(this.context, [this.originalLink]);
      const result = mergeProxyLink(decoded[0][0], this.definition, old[0]?.[0]);
      this.definition = nameProxyFromLink(result, this.base, this.proxy, proxyText(this.definition, ['name']));
      this.updateSections(this.emptyOptions);
      this.linksShown = false;
      this.schedule();
    } catch (error) {
      this.linkError = proxyIssue((error as Error).message);
    } finally { this.busy = false; }
  }

  private closeLink(): void {
    if (this.busy) { return; }
    if (this.linkText === this.originalLink || this.linkDiscard) { this.linksShown = false; }
    else { this.linkDiscard = true; }
  }

  private editValues(field: ProxyField): void {
    this.valuesField = field;
    this.valuesText = field.kind === 'list' ? proxyList(this.definition, field.path).join('\n') :
      field.kind === 'map' ? proxyMapText(this.definition, field) : proxyText(this.definition, field.path);
    this.originalValues = this.valuesText;
    this.valuesError = '';
    this.valuesDiscard = false;
    this.valuesShown = true;
  }

  private closeValues(): void {
    if (this.valuesText === this.originalValues || this.valuesDiscard) { this.valuesShown = false; }
    else { this.valuesDiscard = true; }
  }

  private saveValues(): void {
    const field = this.valuesField;
    if (field === undefined) { return; }
    try {
      if (this.valuesText !== this.originalValues) {
        let value: Object | undefined = this.valuesText;
        if (field.kind === 'list') {
          const items = this.valuesText.split('\n').map((item: string): string => item.trim())
            .filter((item: string): boolean => item !== '');
          value = items.length ? items : undefined;
        } else if (field.kind === 'map') { value = parseProxyMap(this.definition, field, this.valuesText); }
        this.update(field, value);
      }
      this.valuesShown = false;
    } catch (error) { this.valuesError = proxyIssue((error as Error).message); }
  }

  private placeholder(field: ProxyField): ResourceStr {
    if (field.id === 'virtualIpv4') { return 'DHCP'; }
    return field.id === 'name' || (REQUIRED_PROXY_KEYS[this.type()] ?? []).includes(field.path.join('.')) ?
      $r('app.string.local_proxy_required_field') : $r('app.string.local_proxy_optional_field');
  }

  private choices(field: ProxyField): SelectOption[] {
    return proxyChoices(this.type(), field.id).map((value: string): SelectOption => ({ value: value }));
  }

  @Builder
  DividerLine() { Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 }) }

  @Builder
  TypeRow() {
    Row({ space: 8 }) {
      Text($r('app.string.local_proxy_type')).fontSize(16).layoutWeight(1)
      Select(PROTOCOL_OPTIONS).selected(PROXY_TYPES.indexOf(this.type())).value(this.type())
        .accessibilityText($r('app.string.local_proxy_type'))
        .onSelect((_index: number, value: string): void => this.changeType(value))
    }.height(56).width('100%').padding({ left: 16, right: 12 })
  }

  @Builder
  Field(field: ProxyField, optional: boolean) {
    Row({ space: 8 }) {
      if (optional) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.minus_circle')).fontSize(20).fontColor([$r('app.color.status_error')])
        }.width(28).height(36).backgroundColor(Color.Transparent).padding(0)
          .accessibilityText($r('app.string.local_proxy_remove_option'))
          .onClick((): void => this.update(field, undefined, true))
      }
      Text(proxyFieldTitle(field.id)).fontSize(16).fontColor($r('sys.color.font_primary'))
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (field.kind === 'toggle') {
        Toggle({ type: ToggleType.Switch, isOn: proxyValue(this.definition, field.path) === true })
          .selectedColor(this.appStyle.palette.brand).accessibilityText(uiResourceText(this.getUIContext(), proxyFieldTitle(field.id)))
          .onChange((value: boolean): void => this.update(field, value))
      } else if (field.kind === 'choice') {
        Select(this.choices(field)).value(proxyText(this.definition, field.path) ||
          uiResourceText(this.getUIContext(), this.placeholder(field)))
          .selected(proxyChoices(this.type(), field.id).indexOf(proxyText(this.definition, field.path)))
          .constraintSize({ maxWidth: '63%' }).accessibilityText(uiResourceText(this.getUIContext(), proxyFieldTitle(field.id)))
          .onSelect((_index: number, value: string): void => this.update(field, value))
      } else if (field.kind === 'list' || field.kind === 'map' || field.id === 'openVpnCa') {
        Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.NORMAL }) {
          Row({ space: 4 }) {
            if (proxyFieldHasValue(this.definition, field)) {
              Text(field.kind === 'list' ? $r('app.string.local_proxy_item_count',
                proxyList(this.definition, field.path).length) : $r('app.string.action_edit'))
                .fontSize(14).fontColor($r('sys.color.font_secondary'))
            } else {
              Text(this.placeholder(field)).fontSize(14).fontColor($r('sys.color.font_secondary'))
            }
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.font_tertiary')])
          }
        }.height(44).backgroundColor(Color.Transparent).padding(0).accessibilityText(uiResourceText(this.getUIContext(), proxyFieldTitle(field.id)))
          .onClick((): void => this.editValues(field))
      } else {
        TextInput({ text: proxyText(this.definition, field.path), placeholder: this.placeholder(field) })
          .type(field.kind === 'number' ? InputType.Number : field.kind === 'secret' ? InputType.Password : InputType.Normal)
          .textAlign(TextAlign.End).layoutWeight(2).height(44).backgroundColor(Color.Transparent)
          .maxLength(fieldLimit(field)).accessibilityText(uiResourceText(this.getUIContext(), proxyFieldTitle(field.id)))
          .onChange((value: string): void => this.update(field,
            value === '' ? undefined : field.kind === 'number' && field.id !== 'port' ? Number(value) : value))
      }
    }.constraintSize({ minHeight: 56 }).width('100%').padding({ left: 16, right: 12 })
  }

  @Builder
  AuthenticationFields() {
    ForEach(this.authentication, (field: ProxyField, index: number) => {
      if (index > 0) { this.DividerLine() }
      this.Field(field, false)
    }, (field: ProxyField): string => field.id)
  }

  @Builder
  NetworkFields() {
    ForEach(this.network, (field: ProxyField, index: number) => {
      if (index > 0) { this.DividerLine() }
      this.Field(field, false)
    }, (field: ProxyField): string => field.id)
  }

  @Builder
  Options() {
    ForEach(this.shownOptions, (field: ProxyField, index: number) => {
      if (index > 0) { this.DividerLine() }
      this.Field(field, true)
    }, (field: ProxyField): string => field.id)
    if (this.available.length > 0) {
      if (this.shownOptions.length > 0) { this.DividerLine() }
      ListRow({ icon: $r('sys.symbol.plus_circle'), title: $r('app.string.local_proxy_add_option'),
        onTap: (): void => { this.optionsShown = true; } })
    }
  }

  @Builder
  OptionPicker() {
    Scroll() {
      Column({ space: 14 }) {
        ForEach(this.groups, (section: string) => {
          ProxyFormSection({ heading: optionSection(section), content: (): void => this.OptionsInSection(section) })
        }, (section: string): string => section)
      }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
    }.width('100%').align(Alignment.Top)
  }

  @Builder
  OptionsInSection(section: string) {
    ForEach(this.available.filter((field: ProxyField): boolean => field.section === section),
      (field: ProxyField, index: number) => {
        if (index > 0) { this.DividerLine() }
        ListRow({ title: proxyFieldTitle(field.id), chevron: false, onTap: (): void => this.addOption(field) })
      }, (field: ProxyField): string => field.id)
  }

  @Builder
  BufferActions(discard: boolean, close: () => void, confirm: () => void) {
    Row({ space: 12 }) {
      Button(discard ? $r('app.string.added_rules_discard') : $r('app.string.action_cancel'))
        .layoutWeight(1).height(48).enabled(!this.busy).buttonStyle(ButtonStyleMode.NORMAL)
        .onClick((): void => close())
      Button(discard ? $r('app.string.added_rules_resume') : $r('app.string.action_save'))
        .layoutWeight(1).height(48).enabled(!this.busy).onClick((): void => confirm())
    }.width('100%')
  }

  @Builder
  ValuesSheet() {
    Column({ space: 12 }) {
      TextArea({ text: this.valuesText, placeholder: this.valuesField?.kind === 'map' ?
        $r('app.string.local_proxy_map_hint') : this.valuesField?.kind === 'list' ?
        $r('app.string.local_proxy_list_hint') : '' })
        .width('100%').layoutWeight(1).maxLength(32000)
        .onChange((text: string): void => { this.valuesText = text; this.valuesError = ''; this.valuesDiscard = false; })
      if (this.valuesError !== '') { Text(this.valuesError).width('100%').fontColor($r('app.color.status_error')) }
      if (this.valuesDiscard) { Text($r('app.string.added_rules_unsaved')).width('100%') }
      this.BufferActions(this.valuesDiscard, (): void => this.closeValues(), (): void => {
        if (this.valuesDiscard) { this.valuesDiscard = false; } else { this.saveValues(); }
      })
    }.width('100%').height('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }

  @Builder
  LinkSheet() {
    Column({ space: 12 }) {
      TextArea({ text: this.linkText, placeholder: 'vless://…' }).width('100%').layoutWeight(1)
        .enabled(!this.busy).maxLength(LOCAL_PROXY_LIMIT)
        .onChange((text: string): void => { this.linkText = text; this.linkError = ''; this.linkDiscard = false; })
      if (this.linkError !== '') { Text(this.linkError).width('100%').fontColor($r('app.color.status_error')) }
      if (this.linkDiscard) { Text($r('app.string.added_rules_unsaved')).width('100%') }
      this.BufferActions(this.linkDiscard, (): void => this.closeLink(), (): void => {
        if (this.linkDiscard) { this.linkDiscard = false; } else { this.readLink(); }
      })
    }.width('100%').height('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }

  @Builder
  DecisionSheet() {
    Column({ space: 12 }) {
      Text(this.decision === 'delete' && this.proxy !== undefined ? localProxyName(this.proxy) :
        $r('app.string.added_rules_unsaved')).width('100%')
      Button(this.decision === 'delete' ? $r('app.string.action_delete') : $r('app.string.added_rules_discard'),
        { role: ButtonRole.ERROR }).width('100%').height(48).enabled(!this.busy).onClick((): void => {
        if (this.decision === 'delete') { this.remove(); } else { this.onClose(); }
      })
      Button(this.decision === 'delete' ? $r('app.string.action_cancel') : $r('app.string.added_rules_resume'))
        .width('100%').height(48).enabled(!this.busy).onClick((): void => { this.decision = ''; })
    }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 })
  }

  @Builder
  Form() {
    Column({ space: 16 }) {
      if (this.issue !== '' && (this.submitted || this.proxy !== undefined ||
        this.issue === 'local_proxy_rejected' || this.issue === 'local_proxy_core_unavailable')) {
        Text(proxyIssue(this.issue)).fontSize(14).width('100%')
          .fontColor(this.issue === 'local_proxy_core_unavailable' ? $r('sys.color.font_secondary') :
            $r('app.color.status_error'))
      }
      ProxyFormSection({ heading: $r('app.string.local_proxy_basic'), content: (): void => this.BasicFields() })
      if (this.network.length > 0) {
        ProxyFormSection({ heading: $r('app.string.local_proxy_network'),
          content: (): void => this.NetworkFields() })
      }
      if (this.authentication.length > 0) {
        ProxyFormSection({ heading: $r('app.string.local_proxy_auth'),
          content: (): void => this.AuthenticationFields() })
      }
      if (this.available.length > 0 || this.shownOptions.length > 0) {
        ProxyFormSection({ heading: $r('app.string.local_proxy_options'), content: (): void => this.Options() })
      }
      if (this.proxy !== undefined) {
        Button($r('app.string.action_delete'), { role: ButtonRole.ERROR, buttonStyle: ButtonStyleMode.NORMAL })
          .width('100%').height(48).onClick((): void => { this.decision = 'delete'; })
      }
    }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 12, bottom: 24 }).enabled(!this.busy)
  }

  @Builder
  BasicFields() {
    this.Field(PROXY_FIELDS[0], false)
    this.DividerLine()
    this.TypeRow()
    ForEach(this.basic.slice(1), (field: ProxyField) => {
      this.DividerLine()
      this.Field(field, false)
    }, (field: ProxyField): string => field.id)
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 8 }) {
          Blank()
          if (this.checking || this.busy) { LoadingProgress().width(20).height(20).color(this.appStyle.palette.brand) }
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
          }.attributeModifier(HEADER_ACTION).systemMaterial(this.appStyle.headerMaterial()).enabled(!this.busy)
            .accessibilityText($r('app.string.local_proxy_quick_edit')).onClick((): void => { this.openLink(); })
          Button($r('app.string.action_save')).height(40).enabled(!this.busy).onClick((): void => { this.save(); })
        }.width('100%').height(50).padding({ left: PAGE_GUTTER, right: PAGE_GUTTER })
        Scroll() { this.Form() }.width('100%').layoutWeight(1).align(Alignment.Top)
      }.width('100%').height('100%')
      Column().bindSheet($$this.optionsShown, this.OptionPicker, {
        height: SheetSize.LARGE, title: { title: $r('app.string.local_proxy_add_option') }, showClose: true,
        systemMaterial: this.appStyle.sheetMaterial()
      })
      Column().bindSheet($$this.valuesShown, this.ValuesSheet, {
        height: SheetSize.LARGE, title: { title: proxyFieldTitle(this.valuesField?.id ?? '') }, showClose: true,
        systemMaterial: this.appStyle.sheetMaterial(),
        onWillDismiss: (_action: DismissSheetAction): void => this.closeValues()
      })
      Column().bindSheet($$this.linksShown, this.LinkSheet, {
        height: SheetSize.LARGE, title: { title: $r('app.string.local_proxy_quick_edit') }, showClose: true,
        systemMaterial: this.appStyle.sheetMaterial(),
        onWillDismiss: (_action: DismissSheetAction): void => this.closeLink()
      })
      Column().bindSheet(this.decision !== '', this.DecisionSheet, {
        height: SheetSize.FIT_CONTENT, title: { title: this.decision === 'delete' ?
          $r('app.string.action_delete') : $r('app.string.added_rules_unsaved') }, showClose: true,
        systemMaterial: this.appStyle.sheetMaterial(),
        onWillDismiss: (action: DismissSheetAction): void => {
          if (!this.busy) { this.decision = ''; action.dismiss(); }
        }
      })
    }.width('100%').height('100%')
  }
}
