import { common, Configuration, systemConfiguration } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appAppearance } from '../components/AppearanceState';

export class AppearanceLifecycle {
  private loading?: Promise<void>;
  private win?: window.Window;
  private barDark?: boolean;
  private appContext?: common.ApplicationContext;
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
    this.updateBars();
  }

  detach(): void {
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

  private updateBars(): void {
    const win = this.win;
    if (win === undefined || appAppearance.isDark === this.barDark) { return; }
    this.barDark = appAppearance.isDark;
    const ink = this.barDark ? '#FFFFFF' : '#000000';
    win.setWindowSystemBarProperties({ statusBarContentColor: ink, navigationBarContentColor: ink }).catch((e: Error) => {
      hilog.warn(0x0A11, 'Appearance', 'Cannot set system bar contrast: %{public}s', e.message);
    });
  }
}
