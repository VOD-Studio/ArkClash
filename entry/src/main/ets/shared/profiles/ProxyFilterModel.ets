import { newId } from './Store';

export interface ProxyFilterPreset {
  id: string;
  label: string;
  expression: string;
}

export interface ProxyFilterSnapshot {
  revision: string;
  presets: ProxyFilterPreset[];
}

export const PROXY_FILTER_LABEL_LIMIT = 64;
export const PROXY_FILTER_EXPRESSION_LIMIT = 1024;

export function proxyFilterPresets(): ProxyFilterPreset[] {
  return [
    { id: 'hk', label: 'Hong Kong', expression: '(?i)🇭🇰|港|(?<![a-z])hk(?![a-z])|hong\\s*kong' },
    { id: 'tw', label: 'Taiwan', expression: '(?i)🇹🇼|台湾|台灣|台北|新北|彰化|(?<![a-z])tw(?![a-z])|taiwan' },
    { id: 'jp', label: 'Japan', expression: '(?i)🇯🇵|日本|东京|東京|大阪|埼玉|(?<![a-z])jp(?![a-z])|japan|tokyo|osaka' },
    { id: 'sg', label: 'Singapore', expression: '(?i)🇸🇬|新加坡|狮城|獅城|(?<![a-z])sg(?![a-z])|singapore' },
    { id: 'us', label: 'United States',
      expression: '(?i)🇺🇸|美国|美國|美西|美东|美東|洛杉矶|圣何塞|西雅图|硅谷|纽约|(?<![a-z])usa?(?![a-z])|united\\s*states' },
    { id: 'kr', label: 'South Korea',
      expression: '(?i)🇰🇷|韩国|韓國|首尔|首爾|(?<![a-z])kr(?![a-z])|korea|seoul' },
    { id: 'uk', label: 'United Kingdom',
      expression: '(?i)🇬🇧|英国|英國|伦敦|倫敦|(?<![a-z])(uk|gb)(?![a-z])|united\\s*kingdom|britain|london' },
    { id: 'traffic', label: 'Remaining Traffic', expression: '(?i)剩余|剩餘|已用|流量\\s*[:：]|traffic|remaining' },
    { id: 'expiry', label: 'Expiry Date', expression: '(?i)到期|过期|過期|有效期|expir' },
    { id: 'reset', label: 'Traffic Reset', expression: '(?i)重置|reset' },
    { id: 'notices', label: 'Website & Notices',
      expression: '(?i)官网|官網|网址|網址|域名|公告|套餐|客服|群组|群組|频道|頻道|website|telegram|(?<![a-z])tg(?![a-z])' }
  ];
}

export function newProxyFilter(label: string, expression: string, id: string = ''): ProxyFilterPreset {
  return { id: id || newId('pf'), label: label.trim(), expression: expression.trim() };
}

export function proxyFilterProblem(item: ProxyFilterPreset, presets: ProxyFilterPreset[]): string {
  if (item.label === '' || item.label.length > PROXY_FILTER_LABEL_LIMIT || /[\x00\r\n]/.test(item.label)) {
    return 'proxy_filter_label';
  }
  if (presets.some((preset: ProxyFilterPreset): boolean => preset.id !== item.id && preset.label === item.label)) {
    return 'proxy_filter_duplicate';
  }
  if (item.expression === '' || item.expression.length > PROXY_FILTER_EXPRESSION_LIMIT ||
    /[\x00\r\n]/.test(item.expression)) {
    return 'proxy_filter_expression';
  }
  return '';
}

export function checkProxyFilterSnapshot(snapshot: ProxyFilterSnapshot): ProxyFilterSnapshot {
  if (snapshot === null || typeof snapshot.revision !== 'string' || snapshot.revision.length === 0 ||
    snapshot.revision.length > 80 || !Array.isArray(snapshot.presets) || snapshot.presets.length > 500) {
    throw new Error('proxy_filter_store');
  }
  const ids = new Set<string>();
  const labels = new Set<string>();
  for (const preset of snapshot.presets) {
    if (preset === null || typeof preset.id !== 'string' || !/^[a-z0-9-]{1,80}$/.test(preset.id) ||
      typeof preset.label !== 'string' || typeof preset.expression !== 'string' || preset.label !== preset.label.trim() ||
      preset.expression !== preset.expression.trim() || ids.has(preset.id) || labels.has(preset.label) ||
      proxyFilterProblem(preset, []) !== '') {
      throw new Error('proxy_filter_store');
    }
    ids.add(preset.id);
    labels.add(preset.label);
  }
  return snapshot;
}

export function searchProxyFilters(presets: ProxyFilterPreset[], query: string): ProxyFilterPreset[] {
  const words = query.toLowerCase().trim().split(/\s+/);
  return presets.filter((preset: ProxyFilterPreset): boolean => {
    const text = `${preset.label}\n${preset.expression}`.toLowerCase();
    return words.every((word: string): boolean => text.includes(word));
  });
}
