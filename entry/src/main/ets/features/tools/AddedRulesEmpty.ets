import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { EmptyAction, EmptyKind, IllustratedEmpty } from '../../components/IllustratedEmpty';

/**
 * 附加规则页的占位：空列表时是一叠规则卡插画、一句说明和「添加规则」「快捷操作」两个入口；
 * 搜索无结果和读取失败用同一套版式，换成单个图标块。
 */
@ComponentV2
export struct AddedRulesEmpty {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param kind: EmptyKind = 'empty';
  @Param motion: boolean = true;
  @Param available: boolean = true;
  @Event onAdd: () => void = (): void => {};
  @Event onPresets: () => void = (): void => {};
  @Event onRetry: () => void = (): void => {};

  @Builder
  Bar(width: number, height: number, color: ResourceColor) {
    Row().width(width).height(height).borderRadius(height / 2).backgroundColor(color)
  }

  /** 插画最前面的规则卡：分流图标、两道文字骨架和绿色的直连胶囊。 */
  @Builder
  FrontContent() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.arrow_triangle_divide')).fontSize(18).fontColor([this.appStyle.palette.brand])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor(this.appStyle.palette.brandSoft)
      Column({ space: 6 }) {
        this.Bar(86, 8, this.appStyle.palette.track)
        this.Bar(52, 6, this.appStyle.palette.divider)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Row() {
        Circle({ width: 6, height: 6 }).fill($r('app.color.status_connected'))
      }
      .width(40)
      .height(20)
      .borderRadius(10)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.success_soft'))
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  Actions() {
    if (this.kind === 'empty') {
      EmptyAction({ icon: $r('sys.symbol.plus'), label: $r('app.string.added_rules_add'), primary: true,
        motion: this.motion, available: this.available, onPress: (): void => this.onAdd() })
      EmptyAction({ icon: $r('sys.symbol.bolt'), label: $r('app.string.added_rules_presets'),
        motion: this.motion, available: this.available, onPress: (): void => this.onPresets() })
    } else {
      EmptyAction({ icon: $r('sys.symbol.arrow_clockwise'), label: $r('app.string.dns_override_retry'),
        motion: this.motion, available: this.available, onPress: (): void => this.onRetry() })
    }
  }

  private title(): Resource {
    if (this.kind === 'failed') { return $r('app.string.added_rules_load_failed'); }
    if (this.kind === 'noMatch') { return $r('app.string.added_rules_no_matches'); }
    return $r('app.string.added_rules_empty_title');
  }

  build() {
    IllustratedEmpty({
      kind: this.kind, motion: this.motion, heading: this.title(),
      hint: this.kind === 'empty' ? $r('app.string.added_rules_empty_hint') : '',
      front: (): void => { this.FrontContent(); },
      actions: (): void => { this.Actions(); }
    })
      .width('100%')
      .height('100%')
  }
}
