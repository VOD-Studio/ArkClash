import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { RecordGrouping, RecordView, RequestFeed } from './RecordLogic';

export interface RecordPreferenceSnapshot {
  feed: RequestFeed;
  grouping: RecordGrouping;
  requests: Record<string, number>;
  connections: Record<string, number>;
  dns: Record<string, number>;
}

let recordPreferences: Promise<preferences.Preferences> | undefined;
let recordPreferenceWrites: Promise<void> = Promise.resolve();

function settings(context: common.UIAbilityContext): Promise<preferences.Preferences> {
  if (recordPreferences !== undefined) {
    return recordPreferences;
  }
  const pending = preferences.getPreferences(context, { name: 'settings' });
  recordPreferences = pending;
  pending.catch((): void => {
    if (recordPreferences === pending) {
      recordPreferences = undefined;
    }
  });
  return pending;
}

function columnIds(view: RecordView): string[] {
  switch (view) {
    case 'requests': return ['time', 'target', 'protocol', 'rule', 'exit', 'traffic', 'download', 'upload'];
    case 'connections': return ['target', 'protocol', 'rule', 'exit', 'downloadSpeed', 'uploadSpeed',
      'traffic', 'download', 'upload', 'duration'];
    case 'dns': return ['time', 'domain', 'type', 'initiator', 'result', 'elapsed', 'upstream'];
  }
}

function copyWidths(view: RecordView, widths: Record<string, number>): Record<string, number> {
  const result: Record<string, number> = {};
  for (const id of columnIds(view)) {
    const size = widths[id];
    if (typeof size === 'number' && Number.isFinite(size) && size >= 48) {
      result[id] = size;
    }
  }
  return result;
}

function parseWidths(view: RecordView, stored: preferences.ValueType): Record<string, number> {
  if (typeof stored !== 'string' || stored === '') {
    return {};
  }
  try {
    const parsed = JSON.parse(stored) as Record<string, number>;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return {};
    }
    return copyWidths(view, parsed);
  } catch (e) {
    return {};
  }
}

export async function loadRecordPreferences(context: common.UIAbilityContext): Promise<RecordPreferenceSnapshot> {
  try {
    await recordPreferenceWrites;
    const prefs = await settings(context);
    const feed = await prefs.get('diagnostics.requestFeed', 'live');
    const grouping = await prefs.get('diagnostics.grouping', 'none');
    const requests = parseWidths('requests', await prefs.get('diagnostics.columnWidths.requests', ''));
    const connections = parseWidths('connections', await prefs.get('diagnostics.columnWidths.connections', ''));
    const dns = parseWidths('dns', await prefs.get('diagnostics.columnWidths.dns', ''));
    return {
      feed: feed === 'recent' ? 'recent' : 'live',
      grouping: grouping === 'host' || grouping === 'rule' || grouping === 'exit' ? grouping : 'none',
      requests: requests, connections: connections, dns: dns
    };
  } catch (e) {
    throw new Error('diagnostics_preferences_failed');
  }
}

function savePreference(context: common.UIAbilityContext, key: string, after: string): Promise<void> {
  const write = recordPreferenceWrites.then(async (): Promise<void> => {
    try {
      const prefs = await settings(context);
      const before = await prefs.get(key, '');
      try {
        await prefs.put(key, after);
        await prefs.flush();
      } catch (e) {
        // 恢复缓存中的旧值，后续不相关保存不能把失败草稿一并写入。
        await prefs.put(key, before);
        throw new Error('diagnostics_preferences_failed');
      }
    } catch (e) {
      throw new Error('diagnostics_preferences_failed');
    }
  });
  recordPreferenceWrites = write.then((): void => {}, (): void => {});
  return write;
}

export function saveRecordFeed(context: common.UIAbilityContext, feed: RequestFeed): Promise<void> {
  if (feed !== 'live' && feed !== 'recent') {
    return Promise.reject<void>(new Error('diagnostics_preferences_failed'));
  }
  return savePreference(context, 'diagnostics.requestFeed', feed);
}

export function saveRecordGrouping(context: common.UIAbilityContext, grouping: RecordGrouping): Promise<void> {
  if (grouping !== 'none' && grouping !== 'host' && grouping !== 'rule' && grouping !== 'exit') {
    return Promise.reject<void>(new Error('diagnostics_preferences_failed'));
  }
  return savePreference(context, 'diagnostics.grouping', grouping);
}

export function saveRecordColumnWidths(context: common.UIAbilityContext, view: RecordView,
  widths: Record<string, number>): Promise<void> {
  if (view !== 'requests' && view !== 'connections' && view !== 'dns') {
    return Promise.reject<void>(new Error('diagnostics_preferences_failed'));
  }
  // 入队前复制并编码，调用者之后修改列宽对象不会改变本次提交。
  const encoded = JSON.stringify(copyWidths(view, widths));
  return savePreference(context, `diagnostics.columnWidths.${view}`, encoded);
}
