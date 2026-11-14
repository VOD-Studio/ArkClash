import { common } from '@kit.AbilityKit';
import { ProxyDensity } from './ProxyLogic';

export function proxyTextScale(ui: UIContext): number {
  const context = ui.getHostContext() as common.UIAbilityContext;
  return ui.isFollowingSystemFontScale() ? Math.min(context.config.fontSizeScale ?? 1, ui.getMaxFontScale()) : 1;
}

export function proxyCardHeight(density: ProxyDensity, scale: number): number {
  // FlClash common.dart：名称行高20、说明18、宽松延迟13，固定留白合计28。
  const base = 28 + (density === 'compact' ? 20 : 40) * scale + 18 * scale;
  return density === 'loose' ? base + 13 * scale + 6 : base;
}
