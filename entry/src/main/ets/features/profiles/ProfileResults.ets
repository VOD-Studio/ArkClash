import { ListSource } from '../../components/ListSource';
import { describeError } from './ProfileErrors';
import { ProfileBatchFailure, ProfileBatchResult } from './ProfileModels';

@ComponentV2
export struct ProfileResults {
  @Param @Require result: ProfileBatchResult;
  private lines: ListSource<ProfileBatchFailure> = new ListSource<ProfileBatchFailure>();

  aboutToAppear(): void { this.lines.replace(this.result.failures); }
  @Monitor('result')
  onResultChange(): void { this.lines.replace(this.result.failures); }

  build() {
    Column({ space: 8 }) {
      Text($r('app.string.profile_batch_result', this.result.succeeded, this.result.skipped, this.result.failures.length))
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      if (this.result.failures.length > 0) {
        List() {
          LazyForEach(this.lines, (failure: ProfileBatchFailure) => {
            ListItem() {
              Column({ space: 4 }) {
                if (failure.line !== undefined) {
                  Text($r('app.string.profile_batch_line', failure.line, failure.name))
                    .fontSize(13)
                    .fontColor($r('sys.color.font_secondary'))
                } else if (failure.name !== '') {
                  Text(failure.name)
                    .fontSize(13)
                    .fontColor($r('sys.color.font_secondary'))
                }
                Text(describeError(failure.error))
                  .fontSize(13)
                  .fontColor($r('app.color.status_error'))
              }
              .alignItems(HorizontalAlign.Start)
              .padding({ top: 6, bottom: 6 })
              .width('100%')
            }
          }, (failure: ProfileBatchFailure, index: number): string => `${failure.id}:${failure.line ?? 0}:${index}`)
        }
        .height(160)
        .width('100%')
      }
    }
    .width('100%')
  }
}
