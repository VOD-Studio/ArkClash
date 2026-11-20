import { url } from '@kit.ArkTS';
import { validSubscriptionUrl } from './Download';

export function installConfigSource(link: string): string | undefined {
  if (link.length > 8192 || !new RegExp('^(clash|clashmeta|flclash)://install-config/?\\?', 'i').test(link)) {
    return undefined;
  }
  try {
    const urls = new url.URL(link).searchParams.getAll('url');
    if (urls.length !== 1) { return undefined; }
    const source = urls[0].trim();
    return validSubscriptionUrl(source) ? source : undefined;
  } catch (error) { return undefined; }
}
