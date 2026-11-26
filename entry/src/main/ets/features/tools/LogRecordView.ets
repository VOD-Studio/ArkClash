import { LogRecord } from '../../client/Logs';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { logLevelLabel } from './LogLabels';

function logTimestamp(time: number): string {
  const date = new Date(time);
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${date.getFullYear()}-${month}-${day} ${date.toTimeString().slice(0, 8)}.${String(date.getMilliseconds()).padStart(3, '0')}`;
}

export function logCopyText(record: LogRecord): string {
  return `${logTimestamp(record.time)} [${record.level}] ${record.message}`;
}

function levelColor(level: string): ResourceColor {
  if (level === 'error') { return $r('app.color.status_error'); }
  if (level === 'warning') { return $r('app.color.warning'); }
  return $r('sys.color.font_secondary');
}

@ReusableV2
@ComponentV2
export struct LogRecordItem {
  @Param @Require record: LogRecord;
  @Local private appStyle: AppearanceState = appAppearance;
  @Event onOpen: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      Column({ space: 5 }) {
        Row({ space: 8 }) {
          Text(new Date(this.record.time).toLocaleTimeString()).fontSize(13).fontColor($r('sys.color.font_secondary'))
          Text(logLevelLabel(this.record.level)).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(levelColor(this.record.level))
        }
        Text(this.record.message).fontSize(15).fontColor($r('sys.color.font_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).width('100%').padding(12)
    }.width('100%').height('auto').constraintSize({ minHeight: 60 }).padding(0).borderRadius(16)
      .backgroundColor(this.appStyle.palette.cardBackground)
      .id('logs-item-' + this.record.id).onClick(this.onOpen)
  }
}

@ComponentV2
export struct LogRecordDetails {
  @Param @Require record: LogRecord;
  @Local private appStyle: AppearanceState = appAppearance;
  @Event onCopy: () => void = () => {};

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Row({ space: 12 }) {
          Text(logTimestamp(this.record.time)).fontSize(14).fontColor($r('sys.color.font_secondary'))
          Text(logLevelLabel(this.record.level)).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(levelColor(this.record.level))
        }
        Text(this.record.message).fontSize(16).width('100%').fontColor($r('sys.color.font_primary'))
          .copyOption(CopyOptions.LocalDevice).textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        Button($r('app.string.logs_copy_record')).buttonStyle(ButtonStyleMode.NORMAL)
          .id('logs-copy-record').onClick(this.onCopy)
      }.alignItems(HorizontalAlign.Start).width('100%').padding(PAGE_GUTTER)
        .backgroundColor(this.appStyle.palette.cardBackground).borderRadius(22)
    }.align(Alignment.TopStart).width('100%').height('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 24 })
  }
}
