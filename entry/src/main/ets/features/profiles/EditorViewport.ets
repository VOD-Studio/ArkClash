import { webview } from '@kit.ArkWeb';

@Builder
function emptyEditorViewport() {}

@ComponentV2
export struct EditorViewport {
  @Param @Require controller: webview.WebviewController;
  @Param ready: boolean = false;
  @BuilderParam content: () => void = emptyEditorViewport;
  private visibleHeight: number = 0;
  private webHeight: number = 0;
  private appliedInset: number = -1;

  @Monitor('ready')
  syncInset(): void {
    if (!this.ready) { this.appliedInset = -1; return; }
    if (this.visibleHeight <= 0 || this.webHeight <= 0) { return; }
    // 两个视口的高度差包含原生标题与编辑工具栏，也适用于半屏编辑器和键盘避让。
    const inset = Math.max(0, this.webHeight - this.visibleHeight);
    if (inset === this.appliedInset) { return; }
    this.appliedInset = inset;
    this.controller.runJavaScript(`window.arkScriptEditor.setTopInset(${inset})`).catch((): void => {
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
    }
    .width('100%').height('100%')
    .onSizeChange((_previous: SizeOptions, next: SizeOptions): void => {
      this.visibleHeight = Number(next.height);
      this.syncInset();
    })
  }
}
