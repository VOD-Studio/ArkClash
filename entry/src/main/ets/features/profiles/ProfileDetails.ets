import { formatBytes, formatDate, formatDateTime } from '../../components/Format';
import { PAGE_GUTTER } from '../../components/Theme';
import { errorString } from '../../shared/profiles/Errors';
import { ProfileSummary } from '../../shared/profiles/Summary';
import { describeError } from './ProfileErrors';
import { ProfileItem, ProfileStore } from './Profiles';

@ComponentV2
export struct ProfileDetails {
  @Param @Require store: ProfileStore;
  @Param @Require item: ProfileItem;
  @Event onEdit: () => void = (): void => {};
  @Local details: ProfileSummary | undefined = undefined;
  @Local failure: string = '';
  private visible: boolean = true;

  aboutToAppear(): void {
    this.visible = true;
    this.store.profileSummary(this.item.id).then((summary: ProfileSummary | undefined): void => {
      if (this.visible) { this.details = summary; }
    }).catch((error: Error): void => { if (this.visible) { this.failure = errorString(error); } });
  }
  aboutToDisappear(): void { this.visible = false; }
  private used(): number { return (this.item.state.usage?.upload ?? 0) + (this.item.state.usage?.download ?? 0); }
  private ratio(): number {
    const total = this.item.state.usage?.total ?? 0;
    return total > 0 ? Math.min(1, Math.max(0, this.used() / total)) : 0;
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text(this.item.name)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Row({ space: 12 }) {
          if (this.store.current === this.item.id) {
            Text($r('app.string.profile_current')).fontColor($r('app.color.brand'))
          }
          if (this.store.connected && this.store.running === this.item.id) {
            Text($r('app.string.profile_running')).fontColor($r('app.color.brand'))
          }
        }
        .width('100%')
        if (this.item.isSubscription) {
          Text(this.item.url)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
          if ((this.item.state.usage?.total ?? 0) > 0) {
            Text($r('app.string.usage_used', formatBytes(this.used()), formatBytes(this.item.state.usage?.total ?? 0)))
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
            Progress({ value: this.ratio() * 100, total: 100, type: ProgressType.Linear })
              .color($r('app.color.brand'))
              .backgroundColor($r('app.color.track'))
              .width('100%')
          }
          if ((this.item.state.usage?.expire ?? 0) > 0) {
            Text($r('app.string.usage_expire', formatDate((this.item.state.usage?.expire ?? 0) * 1000)))
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
          }
        } else {
          Text($r('app.string.profile_source_local')).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        if (this.item.state.updatedAt > 0) {
          Text($r('app.string.profile_updated', formatDateTime(this.item.state.updatedAt)))
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
        }
        if (this.details !== undefined) {
          Text($r('app.string.profile_details_counts', this.details.proxies, this.details.groups.length))
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
        }
        if (this.failure !== '' || this.item.state.error !== undefined) {
          Text(describeError(this.failure || this.item.state.error || 'network'))
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }
        Button($r('app.string.action_edit'), { type: ButtonType.Capsule })
          .width('100%')
          .height(48)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.on_brand'))
          .onClick((): void => this.onEdit())
      }
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
    }
    .height('100%')
    .width('100%')
  }
}
