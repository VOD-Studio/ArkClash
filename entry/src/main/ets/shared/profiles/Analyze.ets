// 配置内容检查和摘要提取。是纯函数，在 TaskPool 里跑（见 Summary.ets），不能引用模块级变量。
import { parse } from 'yaml';

/** 代理组的成员里有要内核计算的部分（proxy-providers、include-all、filter 等），未连接时列不全。 */
export interface SummaryGroup {
  name: string;
  type: string; // 配置里的写法：select、url-test、fallback、load-balance、relay
  members: string[]; // proxies 字段里直接写的成员，按配置顺序
  dynamic: boolean;
}

/** 未连接时界面显示代理组用的摘要（#35）。 */
export interface ProfileSummary {
  groups: SummaryGroup[];
  proxies: number; // 配置里直接写的节点数，不含 proxy-providers
}

export interface AnalyzeResult {
  error: string; // 空串 = 通过；否则是 ProfileErrorCode 加可选的说明，见 Errors.ets
  summary: string; // 通过时是 ProfileSummary 的 JSON
}

// 这几个字段存在时，成员由内核在加载时算出来。
const DYNAMIC_KEYS: string[] = ['use', 'include-all', 'include-all-proxies', 'include-all-providers', 'filter'];

function stringList(value: Object | undefined): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  const result: string[] = [];
  for (const item of value as Object[]) {
    if (typeof item === 'string') {
      result.push(item);
    }
  }
  return result;
}

function isRecord(value: Object | undefined | null): boolean {
  return value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** 内容检查（顶层要有 proxies 或 proxy-providers），通过时一并给出摘要。 */
export function analyzeText(text: string): AnalyzeResult {
  let doc: Object | undefined | null;
  try {
    doc = parse(text) as Object | undefined | null;
  } catch (e) {
    const message = ((e as Error).message ?? '').split('\n')[0];
    return { error: `invalid_yaml:${message}`, summary: '' };
  }
  if (!isRecord(doc)) {
    return { error: 'not_clash', summary: '' };
  }
  const root = doc as Record<string, Object>;
  const proxies = root['proxies'];
  const providers = root['proxy-providers'];
  if (!Array.isArray(proxies) && !isRecord(providers)) {
    return { error: 'not_clash', summary: '' };
  }

  const groups: SummaryGroup[] = [];
  const rawGroups = root['proxy-groups'];
  if (Array.isArray(rawGroups)) {
    for (const item of rawGroups as Object[]) {
      if (!isRecord(item)) {
        continue;
      }
      const g = item as Record<string, Object>;
      const name = g['name'];
      if (typeof name !== 'string') {
        continue;
      }
      const type = g['type'];
      let dynamic = false;
      for (const key of DYNAMIC_KEYS) {
        const v = g[key];
        if (v !== undefined && v !== null && v !== false) {
          dynamic = true;
        }
      }
      groups.push({
        name: name,
        type: typeof type === 'string' ? type : '',
        members: stringList(g['proxies']),
        dynamic: dynamic
      });
    }
  }
  const summary: ProfileSummary = {
    groups: groups,
    proxies: Array.isArray(proxies) ? (proxies as Object[]).length : 0
  };
  return { error: '', summary: JSON.stringify(summary) };
}
