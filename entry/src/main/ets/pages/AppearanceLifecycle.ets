import { common, Configuration, systemConfiguration } from '@kit.AbilityKit';
import { accessibility } from '@kit.AccessibilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appAppearance } from '../components/AppearanceState';

export class AppearanceLifecycle {
  private loading?: Promise<void>;
  private win?: window.Window;
  private barDark?: boolean;
  private appContext?: common.ApplicationContext;
  private readonly transitionColors = (apply: () => void): void => {
    const win = this.win;
    if (win === undefined || !win.isWindowShowing() || accessibility.isAnimationReduceEnabledSync()) {
      apply();
      this.updateBars();
      return;
    }
    win.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, apply);
    this.updateBars(true);
  };
  private readonly systemListener: systemConfiguration.UpdatedCallback = {
    onFontSizeScaleUpdated: (scale: number): void => appAppearance.updateSystemFontScale(scale)
  };

  load(context: common.UIAbilityContext): void {
    this.loading = appAppearance.load(context);
    try {
      const appContext = context.getApplicationContext();
      appContext.onSystemConfigurationUpdated(this.systemListener);
      this.appContext = appContext;
    } catch (e) {
      hilog.warn(0x0A11, 'Appearance', 'Cannot observe system font scale: %{public}s', (e as Error).message);
    }
  }

  async ready(): Promise<void> { await this.loading; }

  attach(win: window.Window): void {
    this.win = win;
    appAppearance.colorModeTransition = this.transitionColors;
    this.updateBars();
  }

  detach(): void {
    if (appAppearance.colorModeTransition === this.transitionColors) { appAppearance.colorModeTransition = undefined; }
    this.win = undefined;
    this.barDark = undefined;
  }

  destroy(): void {
    this.appContext?.offSystemConfigurationUpdated(this.systemListener);
    this.appContext = undefined;
  }

  configurationChanged(config: Configuration): void {
    appAppearance.updateSystem(config);
    this.updateBars();
  }

  private updateBars(animate: boolean = false): void {
    const win = this.win;
    if (win === undefined || appAppearance.isDark === this.barDark) { return; }
    this.barDark = appAppearance.isDark;
    const ink = this.barDark ? '#FFFFFF' : '#000000';
    win.setWindowSystemBarProperties({ statusBarContentColor: ink, navigationBarContentColor: ink,
      enableStatusBarAnimation: animate, enableNavigationBarAnimation: animate }).catch((e: Error) => {
      hilog.warn(0x0A11, 'Appearance', 'Cannot set system bar contrast: %{public}s', e.message);
    });
  }
}
