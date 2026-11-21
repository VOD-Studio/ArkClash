import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { curves } from '@kit.ArkUI';
import { uiResourceText } from '../../components/ResourceText';
import { AppGlyph } from '../../components/AppGlyph';
import { proxyTextScale } from './ProxyMetrics';
import { ProxyGroupView } from './ProxyView';

const PROXY_GROUP_MONOGRAM = new RegExp('[\\p{L}\\p{N}]', 'u');

@ComponentV2
export struct ProxyGroupHeader {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require group: ProxyGroupView;
  @Param online: boolean = false;
  @Param offlineWritable: boolean = false;
  @Param showLocate: boolean = true;
  @Param collapsible: boolean = true;
  @Param active: boolean = true;
  @Param motionEnabled: boolean = false;
  @Event onToggle: () => void = () => {};
  @Event onLocate: () => void = () => {};
  @Event onTest: () => void = () => {};
  @Event onClearPin: () => void = () => {};
  @Local iconFailed: boolean = false;
  @Local textScale: number = 1;

  aboutToAppear(): void {
    this.textScale = proxyTextScale(this.getUIContext());
  }

  @Monitor('group.icon')
  resetIcon(): void {
    this.iconFailed = false;
  }

  private monogram(): string {
    const mark = PROXY_GROUP_MONOGRAM.exec(this.group.name);
    return mark === null ? Array.from(this.group.name)[0] ?? '' : mark[0].toUpperCase();
  }

  private iconExtent(): number {
    return 2 + 37 * this.textScale;
  }

  private bottomRadius(): number {
    if (this.group.reveal.running) {
      return 0;
    }
    return this.group.expanded ? 24 * this.group.floating : 24;
  }

  @Builder
  private groupMenu() {
    Menu() {
      if (this.group.actualRetired) {
        MenuItem({ content: $r('app.string.proxy_actual_retired') })
          .enabled(false)
      }
      if (this.group.pinned !== '') {
        MenuItem({ content: $r('app.string.proxy_pinned_name', this.group.pinned) })
          .enabled(false)
        MenuItem({ content: $r('app.string.proxy_clear_pin') })
          .enabled(this.active && (this.online || this.offlineWritable))
          .onClick(() => this.onClearPin())
      }
    }
    .font({ size: 15, weight: FontWeight.Normal })
  }

  build() {
    Stack({ alignContent: Alignment.End }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          Row() {
            if (this.group.iconStyle !== 'hidden') {
              Stack() {
                if (this.group.icon !== '' && !this.iconFailed) {
                  Image(this.group.icon)
                    .width(this.group.iconStyle === 'filled' ? this.iconExtent() - 12 : this.iconExtent())
                    .height(this.group.iconStyle === 'filled' ? this.iconExtent() - 12 : this.iconExtent())
                    .objectFit(ImageFit.Contain)
                    .onError(() => { this.iconFailed = true; })
                } else {
                  Text(this.monogram())
                    .fontFamily(this.appStyle.fontFamily)
                    .fontSize((this.group.iconStyle === 'filled' ? this.iconExtent() - 12 : this.iconExtent()) * 0.62)
                    .fontWeight(600)
                    .fontColor(this.group.iconStyle === 'filled' ? $r('sys.color.font_secondary') : this.appStyle.palette.brand)
                    .maxFontScale(1)
                }
              }
              .width(this.iconExtent())
              .height(this.iconExtent())
              .borderRadius(14)
              .backgroundColor(this.group.iconStyle === 'filled' ? this.appStyle.palette.surfaceBlock : Color.Transparent)
              .margin({ left: this.group.iconStyle === 'icon' ? 2 : 0, right: this.group.iconStyle === 'icon' ? 10 : 12 })
            } else {
              Blank()
                .width(4)
            }
            Column({ space: 2 }) {
              Text(this.group.name)
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(16)
                .lineHeight(21)
                .fontWeight(600)
                .fontColor($r('sys.color.font_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(this.group.now)
                .fontFamily(this.appStyle.fontFamily)
                .fontSize(12)
                .lineHeight(16)
                .fontWeight(600)
                .fontColor(this.group.actualRetired ? $r('app.color.warning') : $r('sys.color.font_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1)
          if (this.group.expanded) {
            Column()
              .width(this.showLocate ? 64 : 32)
              .height(32)
          } else {
            Text(this.group.type)
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(12)
              .lineHeight(16)
              .fontWeight(600)
              .fontColor($r('sys.color.font_secondary'))
          }
          if (this.collapsible) {
            Stack() {
              AppGlyph({ name: 'chevronDown', iconSize: 20 })
                .rotate({ angle: this.group.expanded ? 180 : 0 })
                .animation(this.motionEnabled ? { curve: curves.springMotion(0.28, 1) } : { duration: 0 })
            }
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor(this.appStyle.palette.surfaceBlock)
          }
        }
        .width('100%')
      }
      .width('100%')
      .height(22 + 37 * this.textScale)
      .padding(6)
      // 卡片色边框给按压反馈留出 4vp 内边距，不缩小整行按钮的命中区。
      .border({ width: 4, color: this.appStyle.palette.cardBackground })
      .borderRadius(24)
      .backgroundColor(Color.Transparent)
      .accessibilityText(this.group.name)
      .accessibilityDescription(uiResourceText(this.getUIContext(), this.group.actualRetired ? $r('app.string.proxy_actual_retired') : this.group.now))
      .enabled(this.active && this.collapsible)
      .onClick(() => this.onToggle())
      if (this.group.expanded) {
        Row() {
          if (this.showLocate) {
            Button({ type: ButtonType.Circle }) {
              AppGlyph({ name: 'locate', iconSize: 19 })
            }
            .width(32)
            .height(32)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .accessibilityText($r('app.string.proxy_locate_selected'))
            .enabled(this.active)
            .onClick(() => this.onLocate())
          }
          Button({ type: ButtonType.Circle }) {
            if (this.group.testing && this.active) {
              LoadingProgress()
                .width(24)
                .height(24)
                .color($r('sys.color.font_primary'))
                .enableLoading(this.active)
            } else {
              AppGlyph({ name: 'bolt', iconSize: 20 })
            }
          }
          .width(32)
          .height(32)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .accessibilityText($r('app.string.proxy_test_current_group'))
          .enabled(this.active && this.online && !this.group.testing)
          .onClick(() => this.onTest())
        }
        .borderRadius(16)
        .backgroundColor(this.appStyle.palette.surfaceBlock)
        // Block 会连子按钮一起拦住；默认命中保留子按钮，并隔离下层的折叠按钮。
        .hitTestBehavior(HitTestMode.Default)
        .margin({ right: this.collapsible ? 48 : 10 })
        .transition(TransitionEffect.IDENTITY)
      }
    }
    .width('100%')
    .height(22 + 37 * this.textScale)
    .borderRadius({ topLeft: 24, topRight: 24,
      bottomLeft: this.bottomRadius(), bottomRight: this.bottomRadius() })
    .backgroundColor(this.appStyle.palette.cardBackground)
    .shadow({ radius: 16 * this.group.lift, offsetY: 4 * this.group.lift,
      color: $r('app.color.dashboard_shadow') })
    .bindContextMenu(this.groupMenu, ResponseType.LongPress)
  }
}
