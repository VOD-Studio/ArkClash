import { AppearanceState, appAppearance } from './AppearanceState';

@Builder
function emptyScrollContent() {}

@ComponentV2
struct ScrollControlsBar {
  @BuilderParam content: () => void = emptyScrollContent;

  build() {
    Column() { this.content() }
      .width('100%').alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct ScrollControls {
  @Param @Require controls: () => void;
  @Param backdrop: 'blur' | 'none' = 'blur';
  @BuilderParam content: () => void = emptyScrollContent;
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private controlsHeight: number = 0;

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 搜索框、筛选和表头会改变高度。连续的安全区让列表在它们后方仍能画到页面标题。
      Column() { this.content() }
        .width('100%').height('100%').safeAreaPadding({ top: this.controlsHeight })
      ScrollControlsBar({ content: this.controls })
        .backgroundColor(this.backdrop === 'blur' && this.controlsHeight > 0 && this.appStyle.glass === 'none' ?
          this.appStyle.palette.pageBackground : Color.Transparent)
        .backdropBlur(this.backdrop === 'blur' && this.controlsHeight > 0 && this.appStyle.glass !== 'none' ? 20 : 0)
        .onSizeChange((_previous: SizeOptions, next: SizeOptions): void => {
          this.controlsHeight = Number(next.height ?? 0);
        })
    }
    .width('100%').height('100%')
  }
}
