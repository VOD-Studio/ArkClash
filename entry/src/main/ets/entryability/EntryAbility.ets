import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStorageV2, window } from '@kit.ArkUI';
import { AppearanceLifecycle } from '../pages/AppearanceLifecycle';
import { ProfileInstallInbox } from '../pages/ProfileInstallInbox';
import { observeWindowInsets } from '../pages/WindowInsets';

const DOMAIN = 0x0A11;
const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private appearance: AppearanceLifecycle = new AppearanceLifecycle();
  private activeStage?: window.WindowStage;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    this.appearance.load(this.context);
    this.acceptInstallLink(want);
  }

  onNewWant(want: Want): void { this.acceptInstallLink(want); }

  private acceptInstallLink(want: Want): void {
    if (want.action !== 'ohos.want.action.viewData' || want.uri === undefined) { return; }
    AppStorageV2.connect(ProfileInstallInbox, () => new ProfileInstallInbox())?.offer(want.uri);
  }

  onConfigurationUpdate(config: Configuration): void {
    this.appearance.configurationChanged(config);
  }

  onDestroy(): void {
    this.appearance.destroy();
  }

  onWindowStageDestroy(): void {
    this.activeStage = undefined;
    this.appearance.detach();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.activeStage = windowStage;
    // 沉浸式布局：页面铺满整个窗口，状态栏和手势条由页面按 WindowInsets 自己避让。
    // 避让区域在首帧前同步取好，避免页面先按 0 布局再跳一下。
    const win = windowStage.getMainWindowSync();
    try {
      observeWindowInsets(win);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'avoid area unavailable: %{public}s', JSON.stringify(e));
    }
    win.setWindowLayoutFullScreen(true).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'setWindowLayoutFullScreen failed: %{public}s', e.message);
    });
    this.appearance.ready().then((): void => {
      if (this.activeStage !== windowStage) { return; }
      this.appearance.attach(win);
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        }
      });
    });
  }
}
