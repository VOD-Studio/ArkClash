import { SymbolGlyphModifier } from '@kit.ArkUI';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';
import { EmptyAction, IllustratedEmpty } from '../../components/IllustratedEmpty';

export type ScriptsEmptyKind = 'empty' | 'failed';

/**
 * 脚本页的占位：空列表时是一叠脚本卡插画、一句说明和「新建脚本」「导入」两个入口，
 * 「导入」在按钮上弹出链接和文件两种来源；读取失败换成警告图标块，只留「重试」。
 */
@ComponentV2
export struct ScriptsEmpty {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param kind: ScriptsEmptyKind = 'empty';
  @Param motion: boolean = true;
  @Param available: boolean = true;
  @Event onCreate: () => void = (): void => {};
  @Event onImportUrl: () => void = (): void => {};
  @Event onImportFile: () => void = (): void => {};
  @Event onRetry: () => void = (): void => {};

  @Builder
  Bar(width: number, height: number, color: ResourceColor) {
    Row().width(width).height(height).borderRadius(height / 2).backgroundColor(color)
  }

  /** 插画最前面的脚本卡：文档图标、两道文字骨架和一枚 JS 胶囊。 */
  @Builder
  FrontContent() {
    Row({ space: 12 }) {
      Stack() {
        SymbolGlyph($r('sys.symbol.doc_text')).fontSize(18).fontColor([this.appStyle.palette.brand])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor(this.appStyle.palette.brandSoft)
      Column({ space: 6 }) {
        this.Bar(78, 8, this.appStyle.palette.track)
        this.Bar(108, 6, this.appStyle.palette.divider)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('JS')
        .fontFamily('monospace')
        .fontSize(11)
        .fontWeight(600)
        .fontColor(this.appStyle.palette.brand)
        .height(20)
        .padding({ left: 7, right: 7 })
        .borderRadius(10)
        .backgroundColor(this.appStyle.palette.brandSoft)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ImportMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.script_import_url'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.link')) })
        .onClick((): void => this.onImportUrl())
      MenuItem({ content: $r('app.string.script_import_file'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.folder')) })
        .onClick((): void => this.onImportFile())
    }
  }

  @Builder
  Actions() {
    if (this.kind === 'empty') {
      EmptyAction({ icon: $r('sys.symbol.plus'), label: $r('app.string.script_create'), primary: true,
        motion: this.motion, available: this.available, onPress: (): void => this.onCreate() })
      EmptyAction({ icon: $r('sys.symbol.square_and_arrow_down'), label: $r('app.string.script_import'),
        motion: this.motion, available: this.available, hasMenu: true,
        menu: (): void => { this.ImportMenu(); } })
    } else {
      EmptyAction({ icon: $r('sys.symbol.arrow_clockwise'), label: $r('app.string.action_retry'),
        motion: this.motion, available: this.available, onPress: (): void => this.onRetry() })
    }
  }

  build() {
    IllustratedEmpty({
      kind: this.kind, motion: this.motion,
      heading: this.kind === 'failed' ? $r('app.string.script_err_store') : $r('app.string.script_no_items'),
      hint: this.kind === 'empty' ? $r('app.string.script_empty_hint') : '',
      front: (): void => { this.FrontContent(); },
      actions: (): void => { this.Actions(); }
    })
      .width('100%')
      .height('100%')
  }
}
