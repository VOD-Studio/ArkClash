import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { uiResourceText } from '../../components/ResourceText';
import { PAGE_GUTTER } from '../../components/Theme';
import { LogListRow } from './LogHistory';
import { logDialReasonLabel, logHasDns, logHasRoute, logLevelLabel, logTimestamp } from './LogLabels';

interface LogDetailField {
  key: string;
  title: ResourceStr;
  text: ResourceStr;
  copyText: string;
}

export function logLevelInk(level: string, brand: number): ResourceColor {
  if (level === 'error') { return $r('app.color.status_error'); }
  if (level === 'warning') { return $r('app.color.warning'); }
  if (level === 'info') { return brand; }
  return $r('sys.color.font_secondary');
}

export function logLevelSurface(level: string, brandSoft: number, neutralSurface: number): ResourceColor {
  if (level === 'error') { return $r('app.color.error_soft'); }
  if (level === 'warning') { return $r('app.color.warning_soft'); }
  if (level === 'info') { return brandSoft; }
  return neutralSurface;
}

function appendLogField(fields: LogDetailField[], key: string, title: ResourceStr, text: string): void {
  if (text !== '') {
    fields.push({ key: key, title: title, text: text, copyText: text });
  }
}

function buildLogDetailFields(row: LogListRow): LogDetailField[] {
  const record = row.record;
  const fields: LogDetailField[] = [];
  const timeText = logTimestamp(record.time);
  fields.push({ key: 'time', title: $r('app.string.diagnostics_time'), text: timeText, copyText: timeText });
  appendLogField(fields, 'tag', $r('app.string.logs_field_tag'), record.tag ?? '');
  if (row.summary !== record.message && row.summary !== '') {
    appendLogField(fields, 'event', $r('app.string.logs_field_event'), row.summary);
  }
  appendLogField(fields, 'target', $r('app.string.diagnostics_target'), record.target ?? '');
  appendLogField(fields, 'rule', $r('app.string.diagnostics_rule'), record.rule ?? '');
  appendLogField(fields, 'proxy', $r('app.string.diagnostics_exit'), record.proxy ?? '');
  appendLogField(fields, 'source', $r('app.string.diagnostics_source'), record.source ?? '');
  appendLogField(fields, 'detail', $r('app.string.logs_field_detail'), record.detail ?? '');
  return fields;
}

@ReusableV2
@ComponentV2
export struct LogRecordItem {
  @Param @Require row: LogListRow;
  @Param active: boolean = true;
  @Local private appStyle: AppearanceState = appAppearance;
  @Event onOpen: () => void = () => {};
  @Event onFilterLevel: (level: string) => void = () => {};
  @Local private levelText: Resource = $r('app.string.general_log_info');
  @Local private tagText: string = '';
  @Local private clockText: string = '';
  @Local private routeMode: boolean = false;
  @Local private dnsMode: boolean = false;
  @Local private isFailure: boolean = false;
  @Local private targetText: string = '';
  @Local private ruleText: string = '';
  @Local private proxyText: string = '';
  @Local private sourceText: string = '';
  @Local private failureText: string = '';
  @Local private dnsSubtitle: string = '';
  @Local private bodyText: string = '';
  @Local private detailText: string = '';

  aboutToAppear(): void { this.present(); }
  aboutToReuse(): void { this.present(); }

  @Monitor('row')
  updatePresentation(): void { this.present(); }

  private present(): void {
    const record = this.row.record;
    this.levelText = logLevelLabel(record.level);
    this.tagText = record.tag ?? '';
    this.clockText = this.row.clock;
    this.routeMode = logHasRoute(record);
    this.dnsMode = !this.routeMode && logHasDns(record);
    this.isFailure = record.event === 'dial_failed' || record.event === 'dns_failed' || record.level === 'error';
    this.targetText = record.target ?? '';
    this.ruleText = record.rule ?? '';
    this.proxyText = record.proxy ?? '';
    this.sourceText = record.source ?? '';
    const detail = record.detail ?? '';
    if (record.event === 'dial_failed') {
      this.failureText = detail !== '' && detail !== record.reason ? `${this.row.summary} · ${detail}` : this.row.summary;
    } else {
      this.failureText = '';
    }
    if (this.dnsMode) {
      this.dnsSubtitle = detail !== '' ? `${this.row.summary} · ${detail}` : this.row.summary;
    } else {
      this.dnsSubtitle = '';
    }
    let body = this.row.summary !== '' ? this.row.summary : record.message;
    const tagPrefix = this.tagText !== '' ? `[${this.tagText}] ` : '';
    if (tagPrefix !== '' && body.startsWith(tagPrefix)) {
      body = body.slice(tagPrefix.length);
    }
    this.bodyText = body;
    this.detailText = !this.routeMode && !this.dnsMode && detail !== '' && detail !== this.bodyText ? detail : '';
  }

  build() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
          Text(this.levelText)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(11)
            .lineHeight(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(logLevelInk(this.row.record.level, this.appStyle.palette.brand))
            .maxLines(1)
        }
        .padding({ left: 7, right: 7, top: 2, bottom: 2 })
        .constraintSize({ minHeight: 0, minWidth: 0 })
        .height('auto')
        .borderRadius(6)
        .backgroundColor(logLevelSurface(this.row.record.level, this.appStyle.palette.brandSoft,
          this.appStyle.palette.surfaceBlock))
        .accessibilityText(uiResourceText(this.getUIContext(), this.levelText))
        .onClick((): void => {
          if (this.active) { this.onFilterLevel(this.row.record.level); }
        })
        if (this.tagText !== '') {
          Text(this.tagText)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(11)
            .lineHeight(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .borderRadius(6)
            .backgroundColor(this.appStyle.palette.surfaceBlock)
            .maxLines(1)
        }
        Blank()
        Text(this.clockText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .lineHeight(15)
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.routeMode) {
        Text(this.targetText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .lineHeight(21)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.failureText !== '') {
          Text(this.failureText)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .lineHeight(18)
            .fontColor(logLevelInk(this.row.record.level, this.appStyle.palette.brand))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.ruleText !== '' || this.proxyText !== '') {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
            if (this.ruleText !== '') {
              Text(this.ruleText)
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(12)
                .lineHeight(17)
                .fontColor($r('sys.color.font_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            if (this.ruleText !== '' && this.proxyText !== '') {
              Text(' → ')
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(12)
                .lineHeight(17)
                .fontColor($r('sys.color.font_tertiary'))
            }
            if (this.proxyText !== '') {
              Text(this.proxyText)
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(12)
                .lineHeight(17)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.appStyle.palette.brand)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .width('100%')
        }
        if (this.sourceText !== '') {
          Text(this.sourceText)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('sys.color.font_tertiary'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      } else if (this.dnsMode) {
        Text(this.targetText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .lineHeight(21)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.dnsSubtitle)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontColor(this.isFailure ? $r('app.color.status_error') : $r('sys.color.font_secondary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.sourceText !== '') {
          Text(this.sourceText)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .lineHeight(16)
            .fontColor($r('sys.color.font_tertiary'))
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      } else {
        Text(this.bodyText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(14)
          .lineHeight(20)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.detailText !== '') {
          Text(this.detailText)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .lineHeight(18)
            .fontColor(this.isFailure ? logLevelInk(this.row.record.level, this.appStyle.palette.brand) :
              $r('sys.color.font_secondary'))
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .backgroundColor(this.appStyle.palette.cardBackground)
    .borderRadius(20)
    .id('logs-item-' + this.row.id)
    .enabled(this.active)
    .onClick((): void => {
      if (this.active) { this.onOpen(); }
    })
  }
}

@ComponentV2
export struct LogRecordDetails {
  @Param @Require row: LogListRow;
  @Local private appStyle: AppearanceState = appAppearance;
  @Event onCopy: () => void = () => {};
  @Event onCopyValue: (text: string) => void = () => {};

  @Computed
  get detailFields(): LogDetailField[] {
    return buildLogDetailFields(this.row);
  }

  @Computed
  get headline(): string {
    const target = this.row.record.target ?? '';
    return target !== '' ? target : this.row.summary;
  }

  @Computed
  get reasonLabel(): ResourceStr {
    const reason = this.row.record.reason ?? '';
    return reason !== '' ? logDialReasonLabel(reason) : '';
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text(logLevelLabel(this.row.record.level))
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(logLevelInk(this.row.record.level, this.appStyle.palette.brand))
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(10)
              .backgroundColor(logLevelSurface(this.row.record.level, this.appStyle.palette.brandSoft,
                this.appStyle.palette.surfaceBlock))
            if ((this.row.record.tag ?? '') !== '') {
              Text(this.row.record.tag ?? '')
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_secondary'))
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(10)
                .backgroundColor(this.appStyle.palette.surfaceBlock)
            }
          }
          .width('100%')
          Text(this.headline)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(17)
            .lineHeight(24)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
            .wordBreak(WordBreak.BREAK_WORD)
          if (this.reasonLabel !== '') {
            Text(this.reasonLabel)
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(14)
              .fontColor(logLevelInk(this.row.record.level, this.appStyle.palette.brand))
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(16)
        .backgroundColor(this.appStyle.palette.cardBackground)
        .borderRadius(22)

        if (this.detailFields.length > 0) {
          Column() {
            ForEach(this.detailFields, (field: LogDetailField, index: number) => {
              if (index > 0) {
                Divider().color(this.appStyle.palette.divider).margin({ left: 16, right: 16 })
              }
              Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
                Row({ space: 16 }) {
                  Text(field.title)
                    .fontFamily(this.appStyle.fontFamily)
                    .fontSize(15)
                    .lineHeight(20)
                    .fontColor($r('sys.color.font_primary'))
                    .constraintSize({ maxWidth: '40%' })
                  Text(field.text)
                    .fontFamily(this.appStyle.fontFamily)
                    .fontSize(14)
                    .lineHeight(20)
                    .fontColor($r('sys.color.font_secondary'))
                    .textAlign(TextAlign.End)
                    .wordBreak(WordBreak.BREAK_WORD)
                    .layoutWeight(1)
                }
                .width('100%')
                .constraintSize({ minHeight: 50 })
                .alignItems(VerticalAlign.Center)
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              }
              .width('100%')
              .padding(0)
              .onClick((): void => { this.onCopyValue(field.copyText); })
            }, (field: LogDetailField): string => field.key)
          }
          .width('100%')
          .backgroundColor(this.appStyle.palette.cardBackground)
          .borderRadius(22)
          .clip(true)
        }

        Column({ space: 8 }) {
          Text($r('app.string.logs_raw_message'))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_secondary'))
          Text(this.row.record.message)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(14)
            .lineHeight(20)
            .width('100%')
            .fontColor($r('sys.color.font_primary'))
            .wordBreak(WordBreak.BREAK_WORD)
            .copyOption(CopyOptions.LocalDevice)
            .textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(16)
        .backgroundColor(this.appStyle.palette.cardBackground)
        .borderRadius(22)

        Button($r('app.string.logs_copy_record'), { type: ButtonType.Capsule })
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.appStyle.palette.onBrand)
          .backgroundColor(this.appStyle.palette.brand)
          .width('100%')
          .height(48)
          .id('logs-copy-record')
          .onClick(this.onCopy)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 28 })
    }
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
  }
}
