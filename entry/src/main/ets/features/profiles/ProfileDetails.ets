import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { formatBytes, formatDate, formatDateTime } from '../../components/Format';
import { PAGE_GUTTER } from '../../components/Theme';
import { errorString } from '../../shared/profiles/Errors';
import { ProfileSummary } from '../../shared/profiles/Summary';
import { describeError } from './ProfileErrors';
import { ProfileItem, ProfileStore } from './Profiles';

@ComponentV2
export struct ProfileDetails {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require store: ProfileStore;
  @Param @Require item: ProfileItem;
  @Event onEdit: () => void = (): void => {};
  @Local details: ProfileSummary | undefined = undefined;
  @Local sourceShown: boolean = false;
  @Local sourceText: string = '';
  @Local loadingSource: boolean = false;
  private visible: boolean = true;

  aboutToAppear(): void {
    this.visible = true;
    this.store.profileSummary(this.item.id).then((summary: ProfileSummary | undefined): void => {
      if (this.visible) { this.details = summary; }
    }).catch((error: Error): void => this.toastFailure(errorString(error)));
  }
  aboutToDisappear(): void { this.visible = false; }
  private toastFailure(failure: string): void {
    if (this.visible) { this.getUIContext().getPromptAction().showToast({ message: describeError(failure) }); }
  }
  private used(): number { return (this.item.state.usage?.upload ?? 0) + (this.item.state.usage?.download ?? 0); }
  private ratio(): number {
    const total = this.item.state.usage?.total ?? 0;
    return total > 0 ? Math.min(1, Math.max(0, this.used() / total)) : 0;
  }

  private async openSource(): Promise<void> {
    if (this.loadingSource) { return; }
    this.loadingSource = true;
    try {
      const text = await this.store.source(this.item.id);
      if (this.visible) { this.sourceText = text; this.sourceShown = true; }
    } catch (e) {
      this.toastFailure(errorString(e as Object));
    } finally {
      if (this.visible) { this.loadingSource = false; }
    }
  }

  @Builder
  SourcePreview() {
    Scroll() {
      Text(this.sourceText)
        .fontFamily('monospace')
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .copyOption(CopyOptions.LocalDevice)
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
    }
    .width('100%').height('100%').align(Alignment.TopStart)
  }

  build() {
    Scroll() {
      Column({ space: 24 }) {
        Text(this.item.name)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(17)
          .lineHeight(22)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        Row({ space: 12 }) {
          if (this.store.current === this.item.id) {
            Text($r('app.string.profile_current')).fontFamily(this.appStyle.fontFamily).fontColor(this.appStyle.palette.brand)
          }
          if (this.store.coreReady && this.store.running === this.item.id) {
            Text($r('app.string.profile_running')).fontFamily(this.appStyle.fontFamily).fontColor(this.appStyle.palette.brand)
          }
        }
        .width('100%')
        if (this.item.isSubscription) {
          Text(this.item.url)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(15).lineHeight(20)
            .fontColor($r('sys.color.font_secondary'))
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
          if ((this.item.state.usage?.total ?? 0) > 0) {
            Text($r('app.string.usage_used', formatBytes(this.used()), formatBytes(this.item.state.usage?.total ?? 0)))
              .fontFamily(this.appStyle.fontFamily)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
            Progress({ value: this.ratio() * 100, total: 100, type: ProgressType.Linear })
              .color(this.appStyle.palette.brand)
              .backgroundColor(this.appStyle.palette.track)
              .width('100%')
          }
          if ((this.item.state.usage?.expire ?? 0) > 0) {
            Text($r('app.string.usage_expire', formatDate((this.item.state.usage?.expire ?? 0) * 1000)))
              .fontFamily(this.appStyle.fontFamily)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
          }
        } else {
          Text($r('app.string.profile_source_local')).fontFamily(this.appStyle.fontFamily).fontColor($r('sys.color.font_secondary')).width('100%')
        }
        if (this.item.state.updatedAt > 0) {
          Text($r('app.string.profile_updated', formatDateTime(this.item.state.updatedAt)))
            .fontFamily(this.appStyle.fontFamily)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
        }
        if (this.details !== undefined) {
          Text($r('app.string.profile_details_counts', this.details.proxies, this.details.groups.length))
            .fontFamily(this.appStyle.fontFamily)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
        }
        if (this.item.state.error !== undefined) {
          Text(describeError(this.item.state.error))
            .fontFamily(this.appStyle.fontFamily)
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }
        Column() {
          Row({ space: 16 }) {
            Text($r('app.string.profile_source_preview')).fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(22)
              .fontColor($r('sys.color.font_primary')).layoutWeight(1)
            if (this.loadingSource) {
              LoadingProgress().width(24).height(24).color(this.appStyle.palette.brand)
            } else {
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.font_secondary')])
            }
          }
          .width('100%').height(56).padding({ left: 16, right: 16 })
          .enabled(!this.loadingSource)
          .onClick((): void => { this.openSource(); })
          Row().height(0.5).width('100%').backgroundColor(this.appStyle.palette.divider).margin({ left: 16, right: 14 })
          Row({ space: 16 }) {
            Text($r('app.string.action_edit')).fontFamily(this.appStyle.fontFamily).fontSize(17).lineHeight(22)
              .fontColor($r('sys.color.font_primary')).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.font_secondary')])
          }
          .width('100%').height(56).padding({ left: 16, right: 16 })
          .onClick((): void => this.onEdit())
        }
        .width('100%').backgroundColor(this.appStyle.palette.cardBackground).borderRadius(24)
      }
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
    }
    .height('100%')
    .width('100%')
    .align(Alignment.TopStart)
    .bindSheet($$this.sourceShown, this.SourcePreview(), { title: { title: this.item.name },
      height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: true })
  }
}
