import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { GeoResourceId, validateGeoUrl } from '../../shared/GeoResources';
import { COMPACT_TITLE_LINE_HEIGHT, COMPACT_TITLE_SIZE } from '../../components/Theme';

export function geoErrorText(code: string): ResourceStr {
  switch (code) {
    case 'geo_invalid_settings': return $r('app.string.geo_invalid_settings');
    case 'geo_invalid_url': return $r('app.string.geo_invalid_url');
    case 'geo_invalid_interval': return $r('app.string.geo_invalid_interval');
    case 'geo_settings_conflict': return $r('app.string.geo_settings_conflict');
    case 'geo_invalid_data': return $r('app.string.geo_invalid_data');
    case 'geo_metadata_invalid': return $r('app.string.geo_metadata_invalid');
    case 'geo_timeout': return $r('app.string.geo_timeout');
    case 'geo_download_failed': return $r('app.string.geo_download_failed');
    case 'geo_canceled': return $r('app.string.geo_canceled');
    case 'geo_stale_boot': return $r('app.string.geo_stale_boot');
    default:
      if (new RegExp('^geo_http_[0-9]{3}$').test(code)) {
        return $r('app.string.geo_http_error', code.substring(9));
      }
      return $r('app.string.geo_io');
  }
}

@ObservedV2
export class GeoEditorDraft {
  mode: 'url' | 'interval';
  resourceId: GeoResourceId;
  revision: string;
  original: string;
  @Trace text: string;
  @Trace error: string = '';

  constructor(mode: 'url' | 'interval', resourceId: GeoResourceId, revision: string, text: string) {
    this.mode = mode;
    this.resourceId = resourceId;
    this.revision = revision;
    this.original = text;
    this.text = text;
  }

  changed(): boolean { return this.text !== this.original; }

  validate(): boolean {
    if (this.mode === 'url') {
      this.error = validateGeoUrl(this.text) ? '' : 'geo_invalid_url';
    } else {
      const hours = Number(this.text);
      this.error = new RegExp('^[0-9]+$').test(this.text) && Number.isInteger(hours) &&
        hours >= 1 && hours <= 8760 ? '' : 'geo_invalid_interval';
    }
    return this.error === '';
  }
}

@ComponentV2
export struct GeoResourceEditor {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require draft: GeoEditorDraft;
  @Param saving: boolean = false;
  @Event onSave: () => void = () => {};
  @Event onClose: () => void = () => {};
  @Event onRestore: () => void = () => {};

  build() {
    Scroll() {
      Column({ space: 20 }) {
        Text(this.draft.mode === 'url' ? $r('app.string.geo_edit_url', this.draft.resourceId.toUpperCase()) :
          $r('app.string.geo_interval'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(COMPACT_TITLE_SIZE)
          .lineHeight(COMPACT_TITLE_LINE_HEIGHT)
          .fontWeight(600)
          .width('100%')
        Text(this.draft.mode === 'url' ? $r('app.string.geo_url_hint') : $r('app.string.geo_interval_hint'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
        TextInput({ text: this.draft.text, placeholder: this.draft.mode === 'url' ?
          $r('app.string.geo_url') : $r('app.string.geo_interval_hours') })
          .fontFamily(this.appStyle.fontFamily)
          .type(this.draft.mode === 'url' ? InputType.Normal : InputType.Number)
          .fontSize(16)
          .enabled(!this.saving)
          .accessibilityText(this.draft.mode === 'url' ? $r('app.string.geo_url') :
            $r('app.string.geo_interval_hours'))
          .onChange((text: string): void => { this.draft.text = text; this.draft.error = ''; })
        if (this.draft.error !== '') {
          Text(geoErrorText(this.draft.error))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }
        if (this.draft.mode === 'url') {
          Button($r('app.string.geo_restore_default'))
            .fontFamily(this.appStyle.fontFamily)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .enabled(!this.saving)
            .onClick((): void => { this.onRestore(); })
        }
        Row({ space: 12 }) {
          Button($r('app.string.action_cancel'))
            .fontFamily(this.appStyle.fontFamily)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .layoutWeight(1)
            .enabled(!this.saving)
            .onClick((): void => { this.onClose(); })
          Button($r('app.string.action_save'))
            .fontFamily(this.appStyle.fontFamily)
            .layoutWeight(1)
            .enabled(!this.saving)
            .onClick((): void => { this.onSave(); })
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 24, bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }
}
