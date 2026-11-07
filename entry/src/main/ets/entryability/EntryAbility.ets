import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStorageV2, window } from '@kit.ArkUI';
import { WindowInsets } from '../pages/WindowInsets';

const DOMAIN = 0x0A11;
const TAG = 'EntryAbility';

function updateInsets(win: window.Window, insets: WindowInsets): void {
  insets.top = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height;
  insets.bottom = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR).bottomRect.height;
}

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 沉浸式布局：页面铺满整个窗口，状态栏和手势条由页面按 WindowInsets 自己避让。
    // 避让区域在首帧前同步取好，避免页面先按 0 布局再跳一下。
    const win = windowStage.getMainWindowSync();
    const insets = AppStorageV2.connect(WindowInsets, () => new WindowInsets())!;
    try {
      updateInsets(win, insets);
      win.on('avoidAreaChange', () => updateInsets(win, insets));
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'avoid area unavailable: %{public}s', JSON.stringify(e));
    }
    win.setWindowLayoutFullScreen(true).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', e.message);
    });
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
      }
    });
  }
}
