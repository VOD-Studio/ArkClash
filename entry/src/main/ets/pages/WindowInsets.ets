import { window } from '@kit.ArkUI';
import { windowInsets } from '../components/WindowInsets';

export function observeWindowInsets(win: window.Window): void {
  const insets = windowInsets();
  const update = (): void => {
    insets.top = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
    insets.bottom = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
  };
  update();
  win.on('avoidAreaChange', update);
}
