import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';

export function uiResourceText(context: UIContext, text: ResourceStr): string {
  if (typeof text === 'string') {
    return text;
  }
  const manager = (context.getHostContext() as common.Context).resourceManager;
  if (text.params === undefined || text.params.length <= 1) {
    return manager.getStringSync(text.id);
  }
  const args: Array<string | number> = [];
  // $r 的首项是资源名，后续才是格式参数。
  for (let index = 1; index < text.params.length; index++) {
    const argument: Object = text.params[index];
    if (typeof argument === 'string' || typeof argument === 'number') {
      args.push(argument);
    }
  }
  return manager.getStringSync(text.id, ...args);
}
