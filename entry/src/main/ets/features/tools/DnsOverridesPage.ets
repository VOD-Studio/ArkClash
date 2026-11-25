import { common } from '@kit.AbilityKit';
import {
  DnsOverrideSettings, DnsOverrideValue, DnsPolicyRow, dnsPolicyText, emptyDnsOverrides, parseDnsPolicyText,
  readDnsOverrides, saveDnsOverrides
} from '../../client/DnsOverrides';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { DestinationTitle } from '../../components/DestinationTitle';
import { EmptyState } from '../../components/EmptyState';
import { ListRow } from '../../components/ListRow';
import { uiResourceText } from '../../components/ResourceText';
import { HEADER_ACTION, HEADER_ICON_SIZE, PAGE_GUTTER } from '../../components/Theme';
import { DNS_OVERRIDE_SECTIONS, DnsOverrideField, DnsOverrideSection } from './DnsOverrideFields';
import { SettingsSection } from './SettingsSection';

@ComponentV2
export struct DnsOverridesPage {
  @Param @Require topInset: number;
  @Param foreground: boolean = true;
  @Param reduceMotion: boolean = true;
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private settings: DnsOverrideSettings = emptyDnsOverrides();
  @Local private loading: boolean = true;
  @Local private loadFailed: boolean = false;
  @Local private saving: boolean = false;
  @Local private pickerShown: boolean = false;
  @Local private editorShown: boolean = false;
  @Local private field?: DnsOverrideField;
  @Local private draft: string = '';
  @Local private editorError: ResourceStr = '';
  private pendingEditor?: DnsOverrideField;
  private shown: boolean = false;

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      this.settings = await readDnsOverrides(this.context().filesDir);
      this.loadFailed = false;
    } catch (_error) {
      this.loadFailed = true;
    } finally {
      this.loading = false;
    }
  }

  private toast(message: ResourceStr): void {
    if (this.shown && this.foreground) {
      this.getUIContext().getPromptAction().showToast({ message: message });
    }
  }

  private errorText(error: Error): ResourceStr {
    switch (error.message) {
      case 'dns_override_invalid': return $r('app.string.dns_override_invalid');
      case 'dns_override_conflict': return $r('app.string.dns_override_conflict');
      case 'dns_override_listen_failed': return $r('app.string.dns_override_listen_failed');
      case 'dns_override_unavailable': return $r('app.string.dns_override_unavailable');
      case 'dns_override_proxy_servers_required': return $r('app.string.dns_override_proxy_servers_required');
      default: return $r('app.string.dns_override_save_failed');
    }
  }

  private entry(key: string): DnsOverrideValue | undefined {
    return this.settings.entries[key];
  }

  private fields(section: DnsOverrideSection, added: boolean): DnsOverrideField[] {
    return section.fields.filter((field: DnsOverrideField): boolean => (this.entry(field.key) !== undefined) === added);
  }

  private summary(field: DnsOverrideField): ResourceStr {
    const entry = this.entry(field.key);
    if (Array.isArray(entry)) {
      return $r('app.string.dns_override_count', entry.length);
    }
    if (typeof entry === 'number') { return entry.toString(); }
    return typeof entry === 'string' && entry !== '' ? entry : $r('app.string.dns_override_empty_value');
  }

  private async commit(field: DnsOverrideField, entry?: DnsOverrideValue): Promise<void> {
    if (this.loading || this.loadFailed || this.saving) {
      return;
    }
    const oldEntry = this.entry(field.key);
    if (oldEntry === entry || (Array.isArray(oldEntry) && Array.isArray(entry) &&
      JSON.stringify(oldEntry) === JSON.stringify(entry))) {
      this.editorShown = false;
      return;
    }
    this.saving = true;
    const previous = this.settings;
    const entries: Record<string, DnsOverrideValue> = {};
    for (const key of Object.keys(previous.entries)) {
      if (key !== field.key) {
        entries[key] = previous.entries[key];
      }
    }
    if (entry !== undefined) {
      entries[field.key] = entry;
    }
    // 开关的系统控件先更新状态，失败时将旧值写回。
    if (typeof entry === 'boolean' && this.entry(field.key) !== undefined) {
      this.settings = { revision: previous.revision, entries: entries };
    }
    try {
      const saved = await saveDnsOverrides(this.context(), previous.revision, entries);
      if (this.shown && this.foreground && !this.reduceMotion) {
        this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, (): void => { this.settings = saved; });
      } else {
        this.settings = saved;
      }
      this.editorShown = false;
      if (!DNS_OVERRIDE_SECTIONS.some((section: DnsOverrideSection): boolean => this.fields(section, false).length > 0)) {
        this.pickerShown = false;
      }
      this.toast($r('app.string.dns_override_saved'));
    } catch (error) {
      this.settings = previous;
      const failure = error as Error;
      if (failure.message === 'dns_override_conflict') {
        await this.load();
      }
      if (this.editorShown) {
        this.editorError = this.errorText(failure);
      } else {
        this.toast(this.errorText(failure));
      }
    } finally {
      this.saving = false;
    }
  }

  private openEditor(field: DnsOverrideField): void {
    const source = this.entry(field.key) ?? field.initial;
    this.field = field;
    if (field.kind === 'policy') {
      this.draft = dnsPolicyText(source as DnsPolicyRow[]);
    } else {
      this.draft = Array.isArray(source) ? (source as string[]).join('\n') :
        typeof source === 'number' ? source.toString() : typeof source === 'string' ? source : '';
    }
    this.editorError = '';
    this.editorShown = true;
  }

  private addField(field: DnsOverrideField): void {
    if (field.kind === 'toggle') {
      this.commit(field, field.initial);
      return;
    }
    this.pendingEditor = field;
    this.pickerShown = false;
  }

  private openPendingEditor(): void {
    const pending = this.pendingEditor;
    this.pendingEditor = undefined;
    if (pending !== undefined && this.shown) { this.openEditor(pending); }
  }

  private textPlaceholder(field?: DnsOverrideField): ResourceStr {
    switch (field?.key) {
      case 'listen': return '127.0.0.1:1053';
      case 'fake-ip-range': return '198.18.0.1/16';
      case 'fake-ip-range6': return 'fdfe:dcba:9876::1/64';
      case 'fallback-filter.geoip-code': return 'CN';
      default: return '';
    }
  }

  private saveEditor(): void {
    const field = this.field;
    if (field === undefined) {
      return;
    }
    try {
      if (field.kind === 'policy') {
        this.commit(field, parseDnsPolicyText(this.draft));
      } else if (field.kind === 'list') {
        this.commit(field, this.draft.split(/\r?\n/).map((line: string): string => line.trim())
          .filter((line: string): boolean => line !== ''));
      } else if (field.kind === 'number') {
        const value = this.draft.trim();
        if (!/^\d+$/.test(value)) { throw new Error('dns_override_invalid'); }
        this.commit(field, Number(value));
      } else {
        this.commit(field, this.draft.trim());
      }
    } catch (error) { this.editorError = this.errorText(error as Error); }
  }

  @Builder
  HeaderTitle() {
    DestinationTitle({ titleText: 'DNS' })
  }

  @Builder
  HeaderMenus() {
    if (!this.loading && !this.loadFailed && Object.keys(this.settings.entries).length > 0) {
      Row() {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.plus')).fontSize(HEADER_ICON_SIZE).fontColor([$r('sys.color.font_primary')])
        }
        .attributeModifier(HEADER_ACTION)
        .systemMaterial(this.appStyle.headerMaterial())
        .accessibilityText($r('app.string.dns_override_add'))
        .enabled(!this.saving && DNS_OVERRIDE_SECTIONS.some((section: DnsOverrideSection): boolean =>
          this.fields(section, false).length > 0))
        .onClick((): void => { this.pickerShown = true; })
      }
      .height('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ right: PAGE_GUTTER })
    }
  }

  @Builder
  DividerLine(left: number) {
    Divider().color(this.appStyle.palette.divider).margin({ left: left, right: 16 })
  }

  @Builder
  SettingRow(field: DnsOverrideField) {
    Row() {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.minus')).fontSize(16).fontColor([$r('app.color.status_error')])
      }
      .width(40)
      .height(40)
      .buttonStyle(ButtonStyleMode.NORMAL)
      .accessibilityText($r('app.string.dns_override_remove'))
      .enabled(!this.saving)
      .onClick((): void => { this.commit(field); })
      if (field.kind === 'toggle') {
        Text(field.label)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
          .padding({ left: 12 })
        Toggle({ type: ToggleType.Switch, isOn: this.entry(field.key) === true })
          .accessibilityText(uiResourceText(this.getUIContext(), field.label))
          .selectedColor(this.appStyle.palette.brand)
          .enabled(!this.saving)
          .onChange((checked: boolean): void => { this.commit(field, checked); })
          .margin({ right: 16 })
      } else {
        ListRow({ title: field.label, value: this.summary(field), onTap: (): void => this.openEditor(field) })
          .layoutWeight(1)
          .enabled(!this.saving)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 8 })
    .transition(this.reduceMotion ? TransitionEffect.IDENTITY : TransitionEffect.OPACITY)
  }

  @Builder
  SectionRows(section: DnsOverrideSection, added: boolean) {
    ForEach(this.fields(section, added), (field: DnsOverrideField) => {
      if (this.fields(section, added)[0]?.key !== field.key) {
        this.DividerLine(added ? 60 : 16)
      }
      if (added) {
        this.SettingRow(field)
      } else {
        ListRow({ title: field.label, chevron: field.kind !== 'toggle', onTap: (): void => this.addField(field) })
          .enabled(!this.saving)
      }
    }, (field: DnsOverrideField): string => field.key)
  }

  @Builder
  Sections(added: boolean) {
    ForEach(DNS_OVERRIDE_SECTIONS, (section: DnsOverrideSection) => {
      if (this.fields(section, added).length > 0) {
        SettingsSection({ heading: section.title, rows: (): void => this.SectionRows(section, added) })
          .transition(this.reduceMotion ? TransitionEffect.IDENTITY : TransitionEffect.OPACITY)
      }
    }, (section: DnsOverrideSection): string => section.fields[0].key)
  }

  @Builder
  Picker() {
    Scroll() {
      Column({ space: 16 }) {
        this.Sections(false)
      }
      .width('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
    }
    .width('100%')
    .align(Alignment.Top)
  }

  @Builder
  Editor() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.field?.kind === 'choice') {
          ForEach(this.field?.choices ?? [], (choice: string) => {
            ListRow({ title: choice, chevron: false, value: this.draft === choice ? '✓' : '',
              onTap: (): void => { if (this.field !== undefined) { this.commit(this.field, choice); } } })
              .enabled(!this.saving)
          }, (choice: string): string => choice)
        } else {
          if (this.field?.kind === 'text' || this.field?.kind === 'number') {
            TextInput({ text: this.draft, placeholder: this.textPlaceholder(this.field) })
              .type(this.field?.kind === 'number' ? InputType.Number : InputType.Normal)
              .maxLength(this.field?.kind === 'number' ? 10 : 320)
              .onChange((text: string): void => { this.draft = text; this.editorError = ''; })
          } else {
            Text(this.field?.kind === 'policy' ? $r('app.string.dns_override_policy_hint') :
              $r('app.string.dns_override_list_hint')).fontSize(14).fontColor($r('sys.color.font_secondary'))
            TextArea({ text: this.draft })
              .height(168)
              .maxLength(40 * 1024)
              .onChange((text: string): void => { this.draft = text; this.editorError = ''; })
          }
          Row({ space: 12 }) {
            Button($r('app.string.action_cancel'))
              .buttonStyle(ButtonStyleMode.NORMAL)
              .layoutWeight(1)
              .enabled(!this.saving)
              .onClick((): void => { this.editorShown = false; })
            Button($r('app.string.action_save')).layoutWeight(1).enabled(!this.saving).onClick((): void => this.saveEditor())
          }
          .width('100%')
        }
        if (this.editorError !== '') {
          Text(this.editorError).fontSize(13).fontColor($r('app.color.status_error'))
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
    }
    .width('100%')
    .align(Alignment.Top)
  }

  @Builder
  Content() {
    if (this.loading) {
      LoadingProgress().width(36).height(36).color(this.appStyle.palette.brand)
    } else if (this.loadFailed) {
      EmptyState({
        icon: $r('sys.symbol.connection'), title: $r('app.string.dns_override_load_failed'),
        actionLabel: $r('app.string.dns_override_retry'), onAction: (): void => { this.load(); }
      })
    } else if (Object.keys(this.settings.entries).length === 0) {
      EmptyState({
        icon: $r('sys.symbol.connection'), title: $r('app.string.dns_override_empty'),
        hint: $r('app.string.dns_override_description'), actionLabel: $r('app.string.dns_override_add'),
        onAction: (): void => { if (!this.saving) { this.pickerShown = true; } }
      })
    } else {
      Scroll() {
        Column({ space: 16 }) {
          this.Sections(true)
          Text($r('app.string.dns_override_description'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .lineHeight(18)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding({ left: 16, right: 16 })
        }
        .width('100%')
        .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 16, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
  }

  build() {
    NavDestination() {
      Stack() {
        this.Content()
        Column()
          .bindSheet($$this.pickerShown, this.Picker, {
            title: { title: $r('app.string.dns_override_add') }, height: SheetSize.LARGE,
            preferType: SheetType.BOTTOM, showClose: true, systemMaterial: this.appStyle.sheetMaterial(),
            onWillDismiss: (action: DismissSheetAction): void => { if (!this.saving) { action.dismiss(); } },
            onDisappear: (): void => this.openPendingEditor()
          })
        Column()
          .bindSheet($$this.editorShown, this.Editor, {
            title: { title: this.field?.label ?? 'DNS' },
            height: this.field?.kind === 'list' || this.field?.kind === 'policy' ? SheetSize.LARGE : SheetSize.MEDIUM,
            preferType: SheetType.BOTTOM, showClose: true, systemMaterial: this.appStyle.sheetMaterial(),
            onWillDismiss: (action: DismissSheetAction): void => { if (!this.saving) { action.dismiss(); } }
          })
      }
      .width('100%')
      .height('100%')
    }
    .title(this.HeaderTitle, { systemMaterial: this.appStyle.regularMaterial() })
    .menus(this.HeaderMenus)
    .padding({ top: this.topInset })
    .backgroundColor(this.appStyle.palette.pageBackground)
    .onShown((): void => { this.shown = true; if (!this.saving) { this.load(); } })
    .onHidden((): void => { this.shown = false; })
  }
}
