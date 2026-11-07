import { EmptyState } from '../../components/EmptyState';
import { formatBytes, formatDate, formatDateTime } from '../../components/Format';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsNavigationMenuItemOptions } from '@kit.UIDesignKit';
import { TabPage } from '../../components/TabPage';
import { CARD, PAGE_GUTTER, sheetMaterial } from '../../components/Theme';
import { ProfileStore } from './Profiles';

@ComponentV2
export struct ProfilesPage {
  @Param @Require store: ProfileStore;
  @Param @Require scroller: Scroller;
  @Param topInset: number = 0;
  // 首页的「添加订阅」会把它置为 true，打开链接输入面板。
  @Param sheetRequested: boolean = false;
  @Event onSheetHandled: () => void = () => {};
  @Local sheetShown: boolean = false;
  @Local draftUrl: string = '';

  @Monitor('sheetRequested')
  onSheetRequested(): void {
    if (this.sheetRequested) {
      this.openSheet();
      this.onSheetHandled();
    }
  }

  private usedBytes(): number {
    const usage = this.store.usage;
    return usage === undefined ? 0 : usage.upload + usage.download;
  }

  private totalBytes(): number {
    return this.store.usage?.total ?? 0;
  }

  private expireAt(): number {
    return this.store.usage?.expire ?? 0;
  }

  private menus(): HdsNavigationMenuItemOptions[] {
    return [{
      content: {
        label: $r('app.string.action_add_subscription'),
        icon: new SymbolGlyphModifier($r('sys.symbol.plus')),
        action: () => this.openSheet()
      }
    }];
  }

  private openSheet(): void {
    this.draftUrl = this.store.url;
    this.sheetShown = true;
  }

  build() {
    Column() {
      TabPage({ title: $r('app.string.tab_profiles'), topInset: this.topInset, scroller: this.scroller, menus: this.menus() }) {
        if (this.store.ready) {
          this.ProfileCard()
        } else {
          Column() {
            EmptyState({
              icon: $r('sys.symbol.doc_text'),
              title: $r('app.string.home_no_profile'),
              hint: $r('app.string.home_no_profile_hint'),
              actionLabel: $r('app.string.action_add_subscription'),
              onAction: () => this.openSheet()
            })
          }
          .attributeModifier(CARD)
        }
        if (this.store.error !== '' && !this.sheetShown) {
          Text($r('app.string.download_failed', this.store.error))
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
            .width('100%')
        }
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.sheetShown, this.SubscriptionSheet(), {
      title: { title: $r('app.string.subscription_sheet_title') },
      height: SheetSize.FIT_CONTENT,
      systemMaterial: sheetMaterial(),
      showClose: true,
      onDisappear: () => {
        this.sheetShown = false;
      }
    })
  }

  @Builder
  ProfileCard() {
    Column() {
      Row({ space: 8 }) {
        Text($r('app.string.profile_source_subscription'))
          .fontSize(12)
          .fontColor($r('app.color.brand'))
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(10)
          .backgroundColor($r('app.color.brand_soft'))
        if (this.store.updatedAt > 0) {
          Text($r('app.string.profile_updated', formatDateTime(this.store.updatedAt)))
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
        }
      }

      Text(this.store.name)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 10 })

      if (this.totalBytes() > 0) {
        Row() {
          Text($r('app.string.usage_used', formatBytes(this.usedBytes()), formatBytes(this.totalBytes())))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
          if (this.expireAt() > 0) {
            Text($r('app.string.usage_expire', formatDate(this.expireAt() * 1000)))
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
          }
        }
        .width('100%')
        .margin({ top: 8 })
        Progress({ value: this.usedBytes(), total: this.totalBytes(), type: ProgressType.Linear })
          .width('100%')
          .height(4)
          .color($r('app.color.brand'))
          .backgroundColor($r('app.color.track'))
          .margin({ top: 8 })
      }

      Row({ space: 12 }) {
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 6 }) {
            if (this.store.downloading) {
              LoadingProgress()
                .width(18)
                .height(18)
                .color($r('app.color.brand'))
            }
            Text($r('app.string.action_update'))
              .fontSize(15)
              .fontColor($r('app.color.brand'))
          }
        }
        .height(40)
        .layoutWeight(1)
        .backgroundColor($r('app.color.brand_soft'))
        .enabled(!this.store.downloading)
        .onClick(() => {
          this.store.download(this.store.url);
        })
        Button($r('app.string.action_edit_link'), { type: ButtonType.Capsule })
          .height(40)
          .layoutWeight(1)
          .fontSize(15)
          .fontColor($r('sys.color.font_primary'))
          .backgroundColor($r('app.color.track'))
          .onClick(() => this.openSheet())
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .alignItems(HorizontalAlign.Start)
    .attributeModifier(CARD)
  }

  @Builder
  SubscriptionSheet() {
    Column({ space: 12 }) {
      TextInput({ placeholder: $r('app.string.subscription_link'), text: this.draftUrl })
        .type(InputType.URL)
        .height(48)
        .onChange((value: string) => {
          this.draftUrl = value;
        })
      if (this.store.error !== '') {
        Text($r('app.string.download_failed', this.store.error))
          .fontSize(13)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }
      Button({ type: ButtonType.Capsule }) {
        Row({ space: 8 }) {
          if (this.store.downloading) {
            LoadingProgress()
              .width(20)
              .height(20)
              .color($r('app.color.on_brand'))
          }
          Text($r('app.string.action_save_download'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_brand'))
        }
      }
      .width('100%')
      .height(48)
      .backgroundColor($r('app.color.brand'))
      .enabled(!this.store.downloading && this.draftUrl.trim().length > 0)
      .onClick(async () => {
        if (await this.store.download(this.draftUrl.trim())) {
          this.sheetShown = false;
        }
      })
    }
    .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 8, bottom: 24 })
  }
}
