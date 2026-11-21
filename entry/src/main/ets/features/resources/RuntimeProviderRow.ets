import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { formatUpdatedAgo } from '../../components/Format';
import { providerErrorText, RuntimeProviderRowModel } from './RuntimeProvidersStore';

@ComponentV2
export struct RuntimeProviderRow {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require item: RuntimeProviderRowModel;
  @Param now: number = 0;
  @Param canRefresh: boolean = false;
  @Param canReplace: boolean = false;
  @Event onRefresh: () => void = (): void => {};
  @Event onActions: () => void = (): void => {};

  private vehicleLabel(): Resource {
    switch (this.item.vehicleType) {
      case 'http': return $r('app.string.provider_vehicle_http');
      case 'file': return $r('app.string.provider_vehicle_file');
      default: return $r('app.string.provider_vehicle_inline');
    }
  }

  private ruleMetaText(): string {
    if (this.item.kind !== 'rule') {
      return '';
    }
    return [this.item.behavior, this.item.format].filter((part: string): boolean => part !== '').join(' · ');
  }

  private updatedText(): ResourceStr {
    return this.item.updatedAt > 0 ?
      formatUpdatedAgo(this.item.updatedAt, this.now) :
      $r('app.string.provider_never_updated');
  }

  private hasActions(): boolean {
    return this.item.phase !== 'updating' &&
      ((this.item.updatable && this.canRefresh) || (this.item.replaceable && this.canReplace));
  }

  build() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text(this.item.name)
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(16)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.vehicleLabel())
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor(this.appStyle.palette.surfaceBlock)
            .borderRadius(8)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 6 }) {
          Text(this.item.kind === 'proxy' ?
            $r('app.string.provider_proxy_count', this.item.count) :
            $r('app.string.provider_rule_count', this.item.count))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .fontFeature('"tnum" on')
            .maxLines(1)
          if (this.ruleMetaText() !== '') {
            Text('·')
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(13)
              .fontColor($r('sys.color.font_tertiary'))
            Text(this.ruleMetaText())
              .fontFamily(this.appStyle.fontFamily)
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
          }
          Text('·')
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('sys.color.font_tertiary'))
          Text(this.updatedText())
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')

        if (this.item.error !== '') {
          Text(providerErrorText(this.item.error))
            .fontFamily(this.appStyle.fontFamily)
            .fontSize(13)
            .fontColor($r('app.color.status_error'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.item.phase === 'updating') {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(this.appStyle.palette.brand)
          .accessibilityText($r('app.string.provider_updating'))
      } else if (this.item.updatable) {
        Button({ type: ButtonType.Circle, buttonStyle: ButtonStyleMode.NORMAL }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(18)
            .fontColor([this.canRefresh ? $r('sys.color.font_secondary') : $r('sys.color.font_tertiary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .enabled(this.canRefresh)
        .accessibilityText($r('app.string.action_update'))
        .onClick((): void => { this.onRefresh(); })
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 68 })
    .padding({ left: 16, right: 12, top: 12, bottom: 12 })
    .onClick((): void => {
      if (this.hasActions()) {
        this.onActions();
      }
    })
  }
}
