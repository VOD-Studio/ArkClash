import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { ListSource } from '../../components/ListSource';
import { describeError } from './ProfileErrors';
import { ProfileBatchResult } from './ProfileModels';
import { ProfileResultLine, profileResultLines } from './ProfileResultLines';

@ComponentV2
export struct ProfileResults {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require result: ProfileBatchResult;
  private lines: ListSource<ProfileResultLine> = new ListSource<ProfileResultLine>();

  aboutToAppear(): void { this.refreshLines(); }
  @Monitor('result')
  onResultChange(): void { this.refreshLines(); }

  private refreshLines(): void {
    this.lines.replace(profileResultLines(this.result.failures));
  }

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.profile_batch_result', this.result.succeeded, this.result.skipped, this.result.failures.length))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(13).lineHeight(18)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      if (this.result.failures.length > 0) {
        List() {
          LazyForEach(this.lines, (row: ProfileResultLine, index: number) => {
            ListItem() { ProfileResultLineView({ row: row }) }
              .padding({ top: row.first && index > 0 ? 24 : 0 })
          }, (row: ProfileResultLine): string => row.key)
        }
        .height(Math.min(360, this.result.failures.length * 86))
        .width('100%')
        .scrollBar(BarState.Off)
        .cachedCount(2)
      }
    }
    .width('100%')
  }
}

@ComponentV2
@ReusableV2
struct ProfileResultLineView {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require row: ProfileResultLine;

  build() {
    Column() {
      if (this.row.description) {
        Text(describeError(this.row.error))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13).lineHeight(18)
          .fontColor($r('sys.color.font_secondary'))
          .copyOption(CopyOptions.LocalDevice)
          .width('100%').padding({ top: 8, left: 16, right: 16 })
      } else {
        Text(this.row.line !== undefined ? $r('app.string.profile_batch_line', this.row.line, this.row.name) : this.row.name)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(17).lineHeight(22)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%').height(56).padding({ left: 16, right: 16 })
        if (!this.row.last) {
          Row().height(0.5).width('100%').backgroundColor(this.appStyle.palette.divider).margin({ left: 16, right: 14 })
        }
      }
    }
    .width('100%')
    .backgroundColor(this.row.description ? Color.Transparent : this.appStyle.palette.cardBackground)
    .borderRadius({ topLeft: this.row.first ? 24 : 0, topRight: this.row.first ? 24 : 0,
      bottomLeft: this.row.last ? 24 : 0, bottomRight: this.row.last ? 24 : 0 })
    .clip(true)
  }
}
