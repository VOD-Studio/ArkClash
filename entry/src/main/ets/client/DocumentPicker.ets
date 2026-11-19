import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';

export function documentFileName(uri: string): string {
  const tail = uri.split('/').pop() ?? '';
  try {
    return decodeURIComponent(tail);
  } catch (e) {
    return tail;
  }
}

export async function pickDocumentFile(context: common.UIAbilityContext): Promise<string | undefined> {
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  const uris = await new picker.DocumentViewPicker(context).select(options);
  return uris.length > 0 ? uris[0] : undefined;
}
