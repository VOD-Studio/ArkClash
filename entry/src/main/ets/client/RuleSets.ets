import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import {
  ensureProfilesDir, newId, profileDataPath, profileWorkDir, readOptionalText, removeProfileFile, writeProfileText
} from '../shared/profiles/Store';
import { call, getRuntimeStatus } from './Controller';
import { connection } from './Connection';

export interface RuleSetItem {
  id: string;
  name: string;
  url: string;
  behavior: string;
  format: string;
  content: string;
  count: number;
  updatedAt: number;
}

export interface RuleSetCatalog {
  revision: string;
  items: RuleSetItem[];
}

interface RuleSetChange {
  bootId: string;
  expectedRevision: string;
  revision: string;
  action: string;
  item?: RuleSetItem;
  candidate: string;
  order?: string[];
}

export interface RuleSetPreview {
  text: string;
  truncated: boolean;
}

export const RULE_SET_EDITOR_LIMIT = 256 * 1024;
const RULE_SET_INPUT_LIMIT = 8 * 1024 * 1024;
const RULE_SET_ID = /^[a-z0-9][a-z0-9-]{0,79}$/;

export function newRuleSet(name: string = '', source: string = ''): RuleSetItem {
  return { id: newId('ruleset-'), name: name, url: source, behavior: 'auto', format: 'auto', content: '',
    count: 0, updatedAt: 0 };
}

export async function readRuleSets(filesDir: string): Promise<RuleSetCatalog> {
  const text = await readOptionalText(await profileDataPath(filesDir, 'rule-sets.json'));
  if (text === undefined) { return { revision: 'default', items: [] }; }
  const catalog = JSON.parse(text) as RuleSetCatalog;
  if (!RULE_SET_ID.test(catalog.revision) || !Array.isArray(catalog.items) ||
    catalog.items.some((item: RuleSetItem): boolean => !RULE_SET_ID.test(item.id) || !RULE_SET_ID.test(item.content))) {
    throw new Error('rule_set_input');
  }
  return catalog;
}

export async function readRuleSetPreview(filesDir: string, item: RuleSetItem): Promise<RuleSetPreview> {
  if (!RULE_SET_ID.test(item.id) || !RULE_SET_ID.test(item.content)) { throw new Error('rule_set_input'); }
  const suffix = item.format === 'mrs' ? 'rules' : 'source';
  const file = await fs.open(`${filesDir}/rule-sets/${item.id}.${item.content}.${suffix}`, fs.OpenMode.READ_ONLY);
  try {
    const size = (await fs.stat(file.fd)).size;
    const buffer = new ArrayBuffer(Math.min(size, RULE_SET_EDITOR_LIMIT));
    let offset = 0;
    while (offset < buffer.byteLength) {
      const remaining = new ArrayBuffer(buffer.byteLength - offset);
      const length = await fs.read(file.fd, remaining);
      if (length === 0) { break; }
      new Uint8Array(buffer, offset, length).set(new Uint8Array(remaining, 0, length));
      offset += length;
    }
    const truncated = size > offset;
    const decoder = util.TextDecoder.create('utf-8');
    return { text: decoder.decodeToString(new Uint8Array(buffer, 0, offset), { stream: truncated }),
      truncated: truncated };
  } finally {
    await fs.close(file);
  }
}

export async function changeRuleSets(context: common.UIAbilityContext, catalog: RuleSetCatalog, action: string,
  item?: RuleSetItem, text?: string, uri?: string, order?: string[]): Promise<RuleSetCatalog> {
  const filesDir = context.filesDir;
  const revision = newId('rs-');
  let candidate = '';
  let path = '';
  try {
    if (text !== undefined || uri !== undefined) {
      await ensureProfilesDir(filesDir);
      candidate = revision;
      path = `${profileWorkDir(filesDir)}/${candidate}.ruleset`;
      if (uri !== undefined) {
        const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
        try {
          const size = (await fs.stat(file.fd)).size;
          if (size === 0 || size > RULE_SET_INPUT_LIMIT) { throw new Error('rule_set_content'); }
          await fs.copyFile(file.fd, path);
        } finally {
          await fs.close(file);
        }
      } else {
        await writeProfileText(path, text ?? '');
      }
    }
    let status = await getRuntimeStatus(filesDir).catch((): undefined => undefined);
    if (status?.running !== true) {
      await connection.ensureReady(context).catch((): void => {});
      status = await getRuntimeStatus(filesDir).catch((): undefined => undefined);
    }
    if (status?.running !== true) { throw new Error('rule_set_core'); }
    const request: RuleSetChange = {
      bootId: status.bootId, expectedRevision: catalog.revision, revision: revision,
      action: action, item: item, candidate: candidate, order: order
    };
    try {
      await call(filesDir, http.RequestMethod.POST, '/arkclash/rule-sets', JSON.stringify(request), 90000);
    } catch (error) {
      const committed = await readRuleSets(filesDir).catch((): undefined => undefined);
      if (committed?.revision !== revision) { throw error as Error; }
      return committed;
    }
    return await readRuleSets(filesDir);
  } finally {
    if (path !== '') { await removeProfileFile(path).catch((): void => {}); }
  }
}
