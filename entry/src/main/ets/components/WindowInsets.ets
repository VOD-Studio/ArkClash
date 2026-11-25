import { AppStorageV2 } from '@kit.ArkUI';

/** 主窗口沉浸式布局后的避让区域，px。由 EntryAbility 随窗口变化更新。 */
@ObservedV2
export class WindowInsets {
  @Trace top: number = 0;
  @Trace bottom: number = 0;
}

export function windowInsets(): WindowInsets {
  return AppStorageV2.connect(WindowInsets, () => new WindowInsets())!;
}
