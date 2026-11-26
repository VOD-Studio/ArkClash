import { LogListRow } from './LogHistory';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { PAGE_GUTTER } from '../../components/Theme';
import { logLevelLabel, logTimestamp } from './LogLabels';

function levelColor(level: string): ResourceColor {
  if (level === 'error') { return $r('app.color.status_error'); }
  if (level === 'warning') { return $r('app.color.warning'); }
  return $r('sys.color.font_secondary');
}

@ReusableV2
@ComponentV2
export struct LogRecordItem {
  @Param @Require row: LogListRow;
  @Local private appStyle: AppearanceState = appAppearance;
  @Event onOpen: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }) {
      Column({ space: 5 }) {
        Row({ space: 8 }) {
          Text(new Date(this.row.record.time).toLocaleTimeString()).fontSize(13).fontColor($r('sys.color.font_secondary'))
          Text(logLevelLabel(this.row.record.level)).fontSize(13).fontWeight(FontWeight.Medium)
            .fontColor(levelColor(this.row.record.level))
        }
        Text(this.row.summary).fontSize(15).fontColor($r('sys.color.font_primary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.alignItems(HorizontalAlign.Start).width('100%').padding(12)
    }.width('100%').height('auto').constraintSize({ minHeight: 60 }).padding(0).borderRadius(16)
      .backgroundColor(this.appStyle.palette.cardBackground)
      .id('logs-item-' + this.row.id).onClick(this.onOpen)
  }
}

@ComponentV2
export struct LogRecordDetails {
  @Param @Require row: LogListRow;
  @Local private appStyle: AppearanceState = appAppearance;
  @Event onCopy: () => void = () => {};

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Row({ space: 12 }) {
          Text(logTimestamp(this.row.record.time)).fontSize(14).fontColor($r('sys.color.font_secondary'))
          Text(logLevelLabel(this.row.record.level)).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(levelColor(this.row.record.level))
        }
        if (this.row.summary !== this.row.record.message) {
          Text(this.row.summary).fontSize(17).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
        }
        Text(this.row.record.message).fontSize(16).width('100%').fontColor($r('sys.color.font_primary'))
          .copyOption(CopyOptions.LocalDevice).textSelectable(TextSelectableMode.SELECTABLE_UNFOCUSABLE)
        Button($r('app.string.logs_copy_record')).buttonStyle(ButtonStyleMode.NORMAL)
          .id('logs-copy-record').onClick(this.onCopy)
      }.alignItems(HorizontalAlign.Start).width('100%').padding(PAGE_GUTTER)
        .backgroundColor(this.appStyle.palette.cardBackground).borderRadius(22)
    }.align(Alignment.TopStart).width('100%').height('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, bottom: 24 })
  }
}
