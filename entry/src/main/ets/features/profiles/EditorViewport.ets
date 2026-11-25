import { webview } from '@kit.ArkWeb';
import { AppearanceState, appAppearance } from '../../components/AppearanceState';

@Builder
function emptyEditorViewport() {}

@ComponentV2
export struct EditorViewport {
  @Local private appStyle: AppearanceState = appAppearance;
  @Param @Require controller: webview.WebviewController;
  @Param ready: boolean = false;
  @Param painted: boolean = false;
  @Event onInsetChange: (inset: number) => void = (_inset: number): void => {};
  @BuilderParam content: () => void = emptyEditorViewport;
  @Local private insetSynced: boolean = false;
  private visibleHeight: number = 0;
  private webHeight: number = 0;
  private appliedInset: number = -1;
  private reportedInset: number = -1;

  private reportInset(): void {
    if (this.visibleHeight <= 0 || this.webHeight <= 0) { return; }
    const inset = Math.max(0, this.webHeight - this.visibleHeight);
    if (inset !== this.reportedInset) {
      this.reportedInset = inset;
      this.onInsetChange(inset);
    }
  }

  @Monitor('ready')
  syncInset(): void {
    this.reportInset();
    if (!this.ready) {
      this.appliedInset = -1;
      this.insetSynced = false;
      return;
    }
    if (this.visibleHeight <= 0 || this.webHeight <= 0) { return; }
    // 两个视口的高度差包含原生标题与编辑工具栏，也适用于半屏编辑器和键盘避让。
    const inset = Math.max(0, this.webHeight - this.visibleHeight);
    if (inset === this.appliedInset) {
      this.insetSynced = true;
      return;
    }
    this.appliedInset = inset;
    this.controller.runJavaScript(`window.arkScriptEditor.setTopInset(${inset})`).then((): void => {
      if (this.ready && this.appliedInset === inset) { this.insetSynced = true; }
    }).catch((): void => {
      if (this.appliedInset === inset) { this.appliedInset = -1; }
    });
  }

  build() {
    Stack() {
      Stack() { this.content() }
        .width('100%').height(LayoutPolicy.matchParent)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
        .onSizeChange((_previous: SizeOptions, next: SizeOptions): void => {
          this.webHeight = Number(next.height);
          this.syncInset();
        })
      // 遮蔽 ArkWeb 首次绘制前的默认白底与顶部安全区回填前帧，避免入场闪烁。
      if (!this.ready || !this.painted || !this.insetSynced) {
        Column()
          .width('100%').height(LayoutPolicy.matchParent)
          .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP])
          .backgroundColor(this.appStyle.palette.pageBackground)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%').height('100%')
    .onSizeChange((_previous: SizeOptions, next: SizeOptions): void => {
      this.visibleHeight = Number(next.height);
      this.syncInset();
    })
  }
}
