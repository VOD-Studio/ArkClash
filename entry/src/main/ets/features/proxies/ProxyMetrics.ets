import { common } from '@kit.AbilityKit';
import { ProxyDensity } from './ProxyLogic';

export function proxyTextScale(ui: UIContext): number {
  const context = ui.getHostContext() as common.UIAbilityContext;
  return ui.isFollowingSystemFontScale() ? Math.min(context.config.fontSizeScale ?? 1, ui.getMaxFontScale()) : 1;
}

export function proxyCardHeight(density: ProxyDensity, scale: number): number {
  // 分组列表依赖同一高度计算懒加载位置；协议与延迟共用18vp信息行。
  return 28 + (density === 'compact' ? 20 : 40) * scale + 18 * scale;
}
