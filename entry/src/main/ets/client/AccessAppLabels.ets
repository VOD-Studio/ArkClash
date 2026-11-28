import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// 仅 UI 进程读写，用来显示系统应用选择器返回的应用名；VPN 进程只认包名，不依赖这里。
const STORE = 'access_app_labels';
const KEY = 'labels';
const MAX_LABEL_LENGTH = 64;
let cachedLabels: Map<string, string> | undefined = undefined;

function decodeLabels(text: string): Map<string, string> {
  const labels = new Map<string, string>();
  if (text === '') {
    return labels;
  }
  const raw = JSON.parse(text) as Record<string, string>;
  for (const entry of Object.entries(raw)) {
    if (typeof entry[1] === 'string' && entry[1] !== '') {
      labels.set(entry[0], entry[1].slice(0, MAX_LABEL_LENGTH));
    }
  }
  return labels;
}

export function peekAccessAppLabels(): Map<string, string> | undefined {
  return cachedLabels !== undefined ? new Map<string, string>(cachedLabels) : undefined;
}

export async function readAccessAppLabels(context: common.UIAbilityContext): Promise<Map<string, string>> {
  const store = await preferences.getPreferences(context, { name: STORE });
  const labels = decodeLabels(await store.get(KEY, '') as string);
  cachedLabels = new Map<string, string>(labels);
  return labels;
}

/** 只保留 keep 中仍在名单里的包名，名单删掉的应用名随之清除。 */
export async function saveAccessAppLabels(context: common.UIAbilityContext, labels: Map<string, string>,
  keep: string[]): Promise<void> {
  const record: Record<string, string> = {};
  const next = new Map<string, string>();
  for (const bundle of keep) {
    const label = labels.get(bundle);
    if (label !== undefined && label !== '') {
      const trimmed = label.slice(0, MAX_LABEL_LENGTH);
      record[bundle] = trimmed;
      next.set(bundle, trimmed);
    }
  }
  const store = await preferences.getPreferences(context, { name: STORE });
  await store.put(KEY, JSON.stringify(record));
  await store.flush();
  cachedLabels = next;
}
