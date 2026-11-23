import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { CustomNetworkField, CustomNetworkSection, CustomNetworkValues, customNetworkFields } from
  '../../shared/profiles/CustomNetworkOptions';

const TOGGLE_OPTIONS: SelectOption[] = [{ value: $r('app.string.general_default') },
  { value: $r('app.string.general_on') }, { value: $r('app.string.general_off') }];

function labelFor(field: CustomNetworkField): ResourceStr {
  const key = field.key.split('.').pop() ?? '';
  switch (key) {
    case 'enable': return $r('app.string.custom_network_enabled');
    case 'server': return $r('app.string.custom_ntp_server');
    case 'port': return $r('app.string.local_proxy_field_port');
    case 'interval': return $r('app.string.custom_ntp_interval');
    case 'dialer-proxy': return $r('app.string.custom_ntp_dialer');
    case 'write-to-system': return $r('app.string.custom_ntp_write_system');
    case 'override-destination': return $r('app.string.custom_sniff_destination');
    case 'force-dns-mapping': return $r('app.string.custom_sniff_force_dns');
    case 'parse-pure-ip': return $r('app.string.custom_sniff_parse_ip');
    case 'force-domain': return $r('app.string.custom_sniff_force_domain');
    case 'skip-domain': return $r('app.string.custom_sniff_skip_domain');
    case 'skip-src-address': return $r('app.string.custom_sniff_skip_source');
    case 'skip-dst-address': return $r('app.string.custom_sniff_skip_destination');
    case 'ports': return $r('app.string.custom_sniff_ports');
    default: return key;
  }
}

@ComponentV2
export struct CustomNetworkForm {
  @Local private style: AppearanceState = appAppearance;
  @Param section: CustomNetworkSection = 'ntp';
  @Param settings: CustomNetworkValues = {};
  @Param busy: boolean = false;
  @Event onEdit: (key: string, setting: string | undefined) => void = () => {};
  @Event onYaml: () => void = () => {};

  private toggleIndex(field: CustomNetworkField): number {
    const current = this.settings[field.key];
    return current === 'true' ? 1 : current === 'false' ? 2 : 0;
  }

  private visible(field: CustomNetworkField): boolean {
    const keys = field.key.split('.');
    return keys.length < 3 || this.settings['sniff.' + keys[1]] === 'true';
  }

  @Builder
  FieldName(field: CustomNetworkField) {
    Text(labelFor(field)).fontFamily(this.style.fontFamily).fontSize(16).fontColor($r('sys.color.font_primary'))
  }

  @Builder
  Choice(field: CustomNetworkField) {
    Row({ space: 8 }) {
      Row() { this.FieldName(field) }.layoutWeight(1)
      Select(TOGGLE_OPTIONS).selected(this.toggleIndex(field)).value(TOGGLE_OPTIONS[this.toggleIndex(field)].value)
        .onSelect((index: number): void => this.onEdit(field.key, index === 0 ? undefined : String(index === 1)))
    }.width('100%').constraintSize({ minHeight: 44 })
  }

  @Builder
  Protocol(field: CustomNetworkField) {
    Row({ space: 8 }) {
      Row() { this.FieldName(field) }.layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.settings[field.key] === 'true' })
        .selectedColor(this.style.palette.brand)
        .onChange((isOn: boolean): void => this.onEdit(field.key, isOn ? 'true' : undefined))
    }.width('100%').constraintSize({ minHeight: 48 }).margin({ top: 6 })
  }

  @Builder
  Input(field: CustomNetworkField) {
    Column({ space: 4 }) {
      Row({ space: 8 }) {
        Row() { this.FieldName(field) }.layoutWeight(1)
        if (this.settings[field.key] !== undefined) {
          Button($r('app.string.general_default'), { buttonStyle: ButtonStyleMode.TEXTUAL })
            .onClick((): void => this.onEdit(field.key, undefined))
        }
      }.width('100%').constraintSize({ minHeight: 40 })
      if (field.kind === 'list' || field.kind === 'ports') {
        TextArea({ text: this.settings[field.key] ?? '', placeholder: field.kind === 'ports' ? '80\n8080-8090' :
          $r('app.string.custom_network_list_hint') }).height(96).fontFamily(this.style.fontFamily)
          .onChange((text: string): void => this.onEdit(field.key, text))
      } else {
        TextInput({ text: this.settings[field.key] ?? '', placeholder: $r('app.string.general_default') })
          .type(field.kind === 'text' ? InputType.Normal : InputType.Number).fontFamily(this.style.fontFamily)
          .onChange((text: string): void => this.onEdit(field.key, text === '' ? undefined : text))
      }
    }.width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 8 }) {
        ForEach(customNetworkFields(this.section), (field: CustomNetworkField): void => {
          if (this.visible(field)) {
            if (field.kind === 'protocol') { this.Protocol(field) }
            else if (field.kind === 'toggle') { this.Choice(field) }
            else { this.Input(field) }
          }
        }, (field: CustomNetworkField): string => this.section + ':' + field.key)
        Button($r('app.string.custom_network_yaml'), { buttonStyle: ButtonStyleMode.TEXTUAL })
          .onClick((): void => this.onYaml())
      }.width('100%').padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
        .enabled(!this.busy)
    }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off)
  }
}
