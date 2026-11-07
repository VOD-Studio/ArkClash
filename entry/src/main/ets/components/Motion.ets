import { common } from '@kit.AbilityKit';
import { settings } from '@kit.BasicServicesKit';

/**
 * 系统把动画时长倍率设成 0（关闭动画）时返回 false。ArkUI 的一次性动画会自己跟着倍率走，
 * 无限循环的动效要调用方先问这里，关掉时直接不播（docs/agents/ui.md「减弱动态」）。
 */
export function animationsEnabled(context: Context | undefined): boolean {
  if (context === undefined) {
    return true;
  }
  try {
    const scale = settings.getValueSync(context as common.Context, settings.display.ANIMATOR_DURATION_SCALE, '1');
    return Number(scale) !== 0;
  } catch (e) {
    return true;
  }
}
