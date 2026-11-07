/** 主窗口沉浸式布局后的避让区域，px。由 EntryAbility 写入，页面读取。 */
@ObservedV2
export class WindowInsets {
  @Trace top: number = 0;
  @Trace bottom: number = 0;
}
