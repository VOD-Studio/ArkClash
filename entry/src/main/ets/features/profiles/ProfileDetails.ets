import { accessibility } from '@kit.AccessibilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { curves } from '@kit.ArkUI';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { formatBytes, formatDate, formatDateTime, splitBytes } from '../../components/Format';
import { PAGE_GUTTER } from '../../components/Theme';
import { hostOf } from '../../shared/profiles/Download';
import { errorString } from '../../shared/profiles/Errors';
import { ProfileSummary } from '../../shared/profiles/Summary';
import { DETAIL_CARD_RADIUS, DetailAction, DetailChip, DetailInfoRow, DetailMeter, DetailStat,
  DetailTone } from './ProfileDetailParts';
import { describeError } from './ProfileErrors';
import { ProfileItem, ProfileStore } from './Profiles';

const DAY_MS = 24 * 60 * 60 * 1000;
const EXPIRY_WARN_DAYS = 7;
const COPY_RESET_MS = 1600;
// 区块依次上浮淡入；间隔取到肉眼能分出先后、又不拖慢整体的值，和抽屉上滑同时结束。
const ENTER_STAGGER_MS = 45;
const ENTER_OFFSET = 16;
const ENTER_SPRING: ICurve = curves.springMotion(0.5, 0.92);
const METER_LAG_MS = 140;
const SECTION_TRANSITION: TransitionEffect = TransitionEffect.OPACITY
  .combine(TransitionEffect.translate({ y: -8 }))
  .animation({ curve: ENTER_SPRING });

@ComponentV2
export struct ProfileDetails {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require store: ProfileStore;
  @Param @Require item: ProfileItem;
  @Param runtimePreviewAvailable: boolean = false;
  @Event onEdit: () => void = (): void => {};
  @Event onRuntimePreview: () => void = (): void => {};
  @Local details: ProfileSummary | undefined = undefined;
  @Local detailsLoading: boolean = true;
  @Local sourceShown: boolean = false;
  @Local sourceText: string = '';
  @Local loadingSource: boolean = false;
  @Local entered: boolean = false;
  @Local reduceMotion: boolean = false;
  @Local copied: boolean = false;
  @Local copyTick: number = 0;
  @Local clock: number = Date.now();
  private visible: boolean = true;
  private copyTimer: number = -1;
  private readonly copyEffect: ReplaceSymbolEffect = new ReplaceSymbolEffect(EffectScope.WHOLE);
  private readonly numeric: NumericTextTransition =
    new NumericTextTransition({ flipDirection: FlipDirection.UP, enableBlur: true });
  private reductionListener: (enabled: boolean) => void = (enabled: boolean): void => {
    this.reduceMotion = enabled;
  };

  aboutToAppear(): void {
    this.visible = true;
    this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
    // 减弱动态时首帧就是终态，不播入场。
    this.entered = this.reduceMotion;
    accessibility.onAnimationReduceStateChange(this.reductionListener);
    this.store.profileSummary(this.item.id).then((summary: ProfileSummary | undefined): void => {
      if (this.visible) { this.details = summary; this.detailsLoading = false; }
    }).catch((error: Error): void => {
      if (this.visible) { this.detailsLoading = false; }
      this.toastFailure(errorString(error));
    });
  }

  aboutToDisappear(): void {
    this.visible = false;
    accessibility.offAnimationReduceStateChange(this.reductionListener);
    if (this.copyTimer !== -1) {
      clearTimeout(this.copyTimer);
      this.copyTimer = -1;
    }
  }

  private toast(message: ResourceStr): void {
    if (this.visible) { this.getUIContext().getPromptAction().showToast({ message: message }); }
  }

  private toastFailure(failure: string): void { this.toast(describeError(failure)); }

  @Computed
  get titleText(): string { return this.item.name || hostOf(this.item.url) || this.item.id; }

  @Computed
  get typeGlyph(): Resource {
    if (this.item.isSubscription) { return $r('sys.symbol.cloud'); }
    return this.item.type === 'custom' ? $r('sys.symbol.square_and_pencil') : $r('sys.symbol.doc_text');
  }

  @Computed
  get sourceLabel(): ResourceStr {
    if (this.item.isSubscription) { return $r('app.string.profile_source_subscription'); }
    return this.item.type === 'custom' ? $r('app.string.dash_profile_custom_type') :
      $r('app.string.profile_source_local');
  }

  @Computed
  get upload(): number { return Math.max(0, this.item.state.usage?.upload ?? 0); }

  @Computed
  get download(): number { return Math.max(0, this.item.state.usage?.download ?? 0); }

  @Computed
  get used(): number { return this.upload + this.download; }

  @Computed
  get total(): number { return this.item.state.usage?.total ?? 0; }

  @Computed
  get hasUsage(): boolean { return this.item.isSubscription && this.total > 0; }

  @Computed
  get share(): number { return this.total > 0 ? Math.min(1, this.used / this.total) : 0; }

  @Computed
  get usedParts(): string[] { return splitBytes(this.used); }

  @Computed
  get shareText(): string {
    const percent = this.share * 100;
    if (this.used > 0 && percent < 0.1) { return '<0.1%'; }
    // 向下取整：没用完之前不显示 100%。
    return percent < 10 ? `${(Math.floor(percent * 10) / 10).toFixed(1)}%` : `${Math.floor(percent)}%`;
  }

  @Computed
  get meterTone(): DetailTone | 'warning' {
    if (this.share >= 1) { return 'error'; }
    return this.share >= 0.9 ? 'warning' : 'brand';
  }

  @Computed
  get expireMs(): number { return (this.item.state.usage?.expire ?? 0) * 1000; }

  @Computed
  get expired(): boolean { return this.expireMs > 0 && this.expireMs <= this.clock; }

  @Computed
  get daysLeft(): number { return Math.max(0, Math.floor((this.expireMs - this.clock) / DAY_MS)); }

  @Computed
  get intervalText(): ResourceStr {
    if (!this.item.autoUpdate) { return $r('app.string.profile_detail_off'); }
    const minutes = this.item.intervalMinutes;
    return minutes % 60 === 0 ? $r('app.string.profile_detail_every_hours', minutes / 60) :
      $r('app.string.profile_detail_every_minutes', minutes);
  }

  // 入场顺序只算实际出现的区块，缺了用量或错误时后面的区块不会空等。
  @Computed
  get sections(): string[] {
    const order: string[] = ['hero'];
    if (this.item.state.error !== undefined) { order.push('error'); }
    if (this.hasUsage) { order.push('usage'); }
    order.push('stats', 'info', 'actions');
    return order;
  }

  private delayOf(section: string): number { return Math.max(0, this.sections.indexOf(section)) * ENTER_STAGGER_MS; }

  private enterAnimation(section: string): AnimateParam {
    return this.reduceMotion ? { duration: 0 } : { curve: ENTER_SPRING, delay: this.delayOf(section) };
  }

  private sectionTransition(): TransitionEffect {
    return this.reduceMotion ? TransitionEffect.IDENTITY : SECTION_TRANSITION;
  }

  private toneColor(tone: DetailTone | 'warning'): ResourceColor {
    if (tone === 'error') { return $r('app.color.status_error'); }
    if (tone === 'warning') { return $r('app.color.warning'); }
    return tone === 'brand' ? this.appStyle.palette.brand : $r('sys.color.font_primary');
  }

  private expiryColor(): ResourceColor {
    if (this.expired) { return $r('app.color.status_error'); }
    return this.daysLeft <= EXPIRY_WARN_DAYS ? $r('app.color.warning') : $r('sys.color.font_primary');
  }

  private countText(count: number | undefined): string {
    return count === undefined ? '—' : `${count}`;
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

  private async copyLink(): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.item.url);
      await pasteboard.getSystemPasteboard().setData(data);
    } catch (e) {
      this.toastFailure('io');
      return;
    }
    if (!this.visible) { return; }
    this.toast($r('app.string.copied'));
    this.setCopied(true);
    if (this.copyTimer !== -1) { clearTimeout(this.copyTimer); }
    this.copyTimer = setTimeout((): void => {
      this.copyTimer = -1;
      if (this.visible) { this.setCopied(false); }
    }, COPY_RESET_MS);
  }

  private setCopied(copied: boolean): void {
    if (this.copied === copied) { return; }
    this.copied = copied;
    if (!this.reduceMotion) { this.copyTick++; }
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

  @Builder
  Separator(inset: number) {
    Row().height(0.5).width('100%').backgroundColor(this.appStyle.palette.divider).margin({ left: inset, right: 16 })
  }

  @Builder
  Hero() {
    Row({ space: 14 }) {
      Stack() {
        SymbolGlyph(this.typeGlyph).fontSize(26).fontColor([this.appStyle.palette.brand])
      }
      .width(56)
      .height(56)
      .borderRadius(18)
      .backgroundColor(this.appStyle.palette.profileExpiryTonal)
      Column() {
        Text(this.titleText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(20)
          .lineHeight(26)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        // 会出现、消失的胶囊排在末尾，显隐时前面的胶囊不跟着跳。
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          DetailChip({ shown: this.store.coreReady && this.store.running === this.item.id,
            label: $r('app.string.profile_running'), tone: 'brand', dot: true, motion: !this.reduceMotion })
          DetailChip({ shown: this.store.current === this.item.id, label: $r('app.string.profile_current'),
            icon: $r('sys.symbol.checkmark'), tone: 'brand', motion: !this.reduceMotion })
          DetailChip({ label: this.sourceLabel, motion: !this.reduceMotion })
          DetailChip({ shown: this.item.updating, label: $r('app.string.profile_detail_updating'), busy: true,
            motion: !this.reduceMotion })
        }
        .width('100%')
        .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  ErrorNote() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(20).fontColor([$r('app.color.status_error')])
      Text(describeError(this.item.state.error ?? 'network'))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(14)
        .lineHeight(20)
        .fontColor($r('app.color.status_error'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(16)
    .borderRadius(20)
    .backgroundColor($r('app.color.profile_expiry_error_tonal'))
  }

  @Builder
  Usage() {
    Column() {
      Row() {
        Text($r('app.string.profile_detail_used'))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontWeight(500)
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
        Text(this.shareText)
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(13)
          .lineHeight(18)
          .fontWeight(600)
          .fontFeature('"tnum" on')
          .fontColor(this.toneColor(this.meterTone))
          .contentTransition(this.reduceMotion ? undefined : this.numeric)
      }
      .width('100%')
      Flex({ alignItems: ItemAlign.Baseline }) {
        Text(this.usedParts[0])
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(34)
          .lineHeight(42)
          .fontWeight(700)
          .fontFeature('"tnum" on')
          .fontColor($r('sys.color.font_primary'))
          .contentTransition(this.reduceMotion ? undefined : this.numeric)
        Text(this.usedParts[1])
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(16)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .margin({ left: 4 })
        Text($r('app.string.profile_detail_total', formatBytes(this.total)))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(15)
          .fontFeature('"tnum" on')
          .fontColor($r('sys.color.font_secondary'))
          .margin({ left: 8 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .flexShrink(1)
      }
      .width('100%')
      .margin({ top: 4 })
      DetailMeter({ share: this.share, color: this.toneColor(this.meterTone), shown: this.entered,
        motion: !this.reduceMotion, delayMs: this.delayOf('usage') + METER_LAG_MS })
        .margin({ top: 14 })
      Row({ space: 14 }) {
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.arrow_up')).fontSize(12).fontColor([$r('sys.color.font_secondary')])
          Text(formatBytes(this.upload))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .lineHeight(16)
            .fontFeature('"tnum" on')
            .fontColor($r('sys.color.font_secondary'))
        }
        .accessibilityGroup(true)
        .accessibilityText($r('app.string.profile_detail_upload', formatBytes(this.upload)))
        Row({ space: 3 }) {
          SymbolGlyph($r('sys.symbol.arrow_down')).fontSize(12).fontColor([$r('sys.color.font_secondary')])
          Text(formatBytes(this.download))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .lineHeight(16)
            .fontFeature('"tnum" on')
            .fontColor($r('sys.color.font_secondary'))
        }
        .accessibilityGroup(true)
        .accessibilityText($r('app.string.profile_detail_download', formatBytes(this.download)))
        Blank()
        Text($r('app.string.profile_detail_remaining', formatBytes(Math.max(0, this.total - this.used))))
          .fontFamily(this.appStyle.fontFamily)
          .fontSize(12)
          .lineHeight(16)
          .fontFeature('"tnum" on')
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 18 })
    .borderRadius(DETAIL_CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
  }

  @Builder
  Stats() {
    Row({ space: 10 }) {
      DetailStat({ figure: this.countText(this.details?.proxies), label: $r('app.string.profile_detail_nodes'),
        loading: this.detailsLoading, motion: !this.reduceMotion })
        .layoutWeight(1)
      DetailStat({ figure: this.countText(this.details?.groups.length), label: $r('app.string.card_group'),
        loading: this.detailsLoading, motion: !this.reduceMotion })
        .layoutWeight(1)
      if (this.expireMs > 0) {
        DetailStat({
          figure: this.expired ? $r('app.string.profile_detail_expired') : `${this.daysLeft}`,
          unit: this.expired ? '' : $r('app.string.profile_detail_days_unit'),
          label: this.expired ? formatDate(this.expireMs) : $r('app.string.profile_detail_days_left'),
          tone: this.expiryColor(), motion: !this.reduceMotion
        })
          .layoutWeight(1)
      }
    }
    .width('100%')
  }

  @Builder
  LinkRow() {
    Row({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.link')).fontSize(20).fontColor([$r('sys.color.font_secondary')])
      Text($r('app.string.profile_detail_link'))
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(15)
        .lineHeight(20)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
      // 只露出主机名：完整订阅地址带鉴权参数，截图分享时容易泄露，点按整行复制完整地址。
      Text(hostOf(this.item.url) || '—')
        .fontFamily(this.appStyle.fontFamily)
        .fontSize(14)
        .lineHeight(20)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      SymbolGlyph(this.copied ? $r('sys.symbol.checkmark') : $r('sys.symbol.rectangle_on_rectangle'))
        .fontSize(18)
        .fontColor([this.copied ? this.appStyle.palette.brand : $r('sys.color.font_secondary')])
        .symbolEffect(this.copyEffect, this.copyTick)
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .stateStyles({
      pressed: { .backgroundColor($r('sys.color.interactive_pressed')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .accessibilityGroup(true)
    .accessibilityDescription($r('app.string.action_copy_link'))
    .onClick((): void => { this.copyLink(); })
  }

  @Builder
  Info() {
    Column() {
      if (this.item.isSubscription) {
        this.LinkRow()
        this.Separator(48)
      }
      if (this.expireMs > 0) {
        DetailInfoRow({ icon: $r('sys.symbol.calendar'), label: $r('app.string.profile_detail_expire_at'),
          value: formatDate(this.expireMs),
          tone: this.expired ? $r('app.color.status_error') : $r('sys.color.font_secondary') })
        this.Separator(48)
      }
      DetailInfoRow({ icon: $r('sys.symbol.clock'), label: $r('app.string.profile_detail_updated_at'),
        value: this.item.state.updatedAt > 0 ? formatDateTime(this.item.state.updatedAt) : '—' })
      if (this.item.isSubscription) {
        this.Separator(48)
        DetailInfoRow({ icon: $r('sys.symbol.arrow_2_circlepath'), label: $r('app.string.field_auto_update'),
          value: this.intervalText })
      }
    }
    .width('100%')
    .borderRadius(DETAIL_CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .clip(true)
  }

  @Builder
  Actions() {
    Column() {
      DetailAction({ icon: $r('sys.symbol.doc_plaintext'), label: $r('app.string.profile_source_preview'),
        busy: this.loadingSource, onTap: (): void => { this.openSource(); } })
      if (this.runtimePreviewAvailable) {
        this.Separator(62)
        DetailAction({ icon: $r('sys.symbol.layer'), label: $r('app.string.profile_runtime_preview'),
          onTap: (): void => this.onRuntimePreview() })
      }
      this.Separator(62)
      DetailAction({ icon: $r('sys.symbol.pencil_line'), label: $r('app.string.action_edit'),
        onTap: (): void => this.onEdit() })
    }
    .width('100%')
    .borderRadius(DETAIL_CARD_RADIUS)
    .backgroundColor(this.appStyle.palette.cardBackground)
    .clip(true)
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Column() { this.Hero() }
          .width('100%')
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : ENTER_OFFSET })
          .animation(this.enterAnimation('hero'))
        if (this.item.state.error !== undefined) {
          Column() { this.ErrorNote() }
            .width('100%')
            .opacity(this.entered ? 1 : 0)
            .translate({ y: this.entered ? 0 : ENTER_OFFSET })
            .animation(this.enterAnimation('error'))
            .transition(this.sectionTransition())
        }
        if (this.hasUsage) {
          Column() { this.Usage() }
            .width('100%')
            .opacity(this.entered ? 1 : 0)
            .translate({ y: this.entered ? 0 : ENTER_OFFSET })
            .animation(this.enterAnimation('usage'))
            .transition(this.sectionTransition())
        }
        Column() { this.Stats() }
          .width('100%')
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : ENTER_OFFSET })
          .animation(this.enterAnimation('stats'))
        Column() { this.Info() }
          .width('100%')
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : ENTER_OFFSET })
          .animation(this.enterAnimation('info'))
        Column() { this.Actions() }
          .width('100%')
          .opacity(this.entered ? 1 : 0)
          .translate({ y: this.entered ? 0 : ENTER_OFFSET })
          .animation(this.enterAnimation('actions'))
      }
      .width('100%')
      .padding({ left: PAGE_GUTTER, right: PAGE_GUTTER, top: 4, bottom: 32 })
    }
    .height('100%')
    .width('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .onAppear((): void => { this.entered = true; })
    .bindSheet($$this.sourceShown, this.SourcePreview(), { title: { title: this.item.name },
      height: SheetSize.LARGE, systemMaterial: this.appStyle.sheetMaterial(), showClose: true })
  }
}
