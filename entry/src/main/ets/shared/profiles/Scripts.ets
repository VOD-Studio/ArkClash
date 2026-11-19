import { taskpool, util, url as urlKit } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DirectDownloader, Downloader, hostOf, validSubscriptionUrl } from './Download';
import { candidatePath, ensureProfilesDir, findProfile, newId, profilesDir, readListAsync, readOptionalText,
  removeProfileFile, validProfileId, withProfileStorage, withProfileTask, writeProfileText } from './Store';

const SCRIPT_LIMIT = 4 * 1024 * 1024;
const SCRIPT_STORE_LIMIT = 16 * 1024 * 1024;
export const SCRIPT_TEMPLATE = 'const main = (config) => {\n  return config;\n}';

export interface ScriptDownloadCommand {
  id: string;
  revision: string;
  url: string;
}

export interface ConfigScript {
  id: string;
  revision: string;
  name: string;
  url: string;
  updatedAt: number;
  source: string;
}

export type ExtensionMode = 'standard' | 'script';

export interface ConfigScriptBinding {
  profile: string;
  mode: ExtensionMode;
  scriptId: string;
}

export interface ConfigScriptsSnapshot {
  version: number;
  scripts: ConfigScript[];
  bindings: ConfigScriptBinding[];
}

export function emptyConfigScripts(): ConfigScriptsSnapshot { return { version: 1, scripts: [], bindings: [] }; }

function scriptsPath(filesDir: string): string { return `${profilesDir(filesDir)}/scripts.json`; }

@Concurrent
function decodeScripts(text: string): ConfigScriptsSnapshot {
  const store = JSON.parse(text) as ConfigScriptsSnapshot;
  if (store === null || store.version !== 1 || !Array.isArray(store.scripts) || !Array.isArray(store.bindings)) {
    throw new Error('script_store');
  }
  const scripts = new Set<string>();
  const names = new Set<string>();
  for (const item of store.scripts) {
    if (item === null || !validProfileId(item.id) || scripts.has(item.id) || !validProfileId(item.revision) ||
      typeof item.name !== 'string' || item.name.trim() === '' || item.name.length > 64 || names.has(item.name) ||
      typeof item.url !== 'string' || typeof item.source !== 'string' || !Number.isFinite(item.updatedAt)) {
      throw new Error('script_store');
    }
    scripts.add(item.id);
    names.add(item.name);
  }
  const profiles = new Set<string>();
  for (const binding of store.bindings) {
    if (binding === null || !validProfileId(binding.profile) || profiles.has(binding.profile) ||
      (binding.mode !== 'standard' && binding.mode !== 'script') || typeof binding.scriptId !== 'string' ||
      (binding.scriptId !== '' && !validProfileId(binding.scriptId))) {
      throw new Error('script_store');
    }
    profiles.add(binding.profile);
  }
  return store;
}

@Concurrent
function encodeScripts(store: ConfigScriptsSnapshot, limit: number, scriptLimit: number): string {
  const encoder = new util.TextEncoder();
  for (const item of store.scripts) {
    if (item.source.length > scriptLimit || encoder.encodeInto(item.source).byteLength > scriptLimit) {
      throw new Error('script_size');
    }
  }
  const text = JSON.stringify(store);
  if (encoder.encodeInto(text).byteLength > limit) { throw new Error('script_size'); }
  return text;
}

export async function readConfigScripts(filesDir: string): Promise<ConfigScriptsSnapshot> {
  try {
    const text = await readOptionalText(scriptsPath(filesDir));
    return text === undefined ? emptyConfigScripts() : await taskpool.execute(decodeScripts, text) as ConfigScriptsSnapshot;
  } catch (error) { throw new Error('script_store'); }
}

export function scriptBinding(store: ConfigScriptsSnapshot, id: string): ConfigScriptBinding {
  return store.bindings.find((item: ConfigScriptBinding): boolean => item.profile === id) ??
    { profile: id, mode: 'standard', scriptId: '' };
}

export function scriptIdentity(store: ConfigScriptsSnapshot, profile: string): string | undefined {
  const binding = scriptBinding(store, profile);
  if (binding.mode !== 'script') { return ''; }
  if (binding.scriptId === '') { return 'script'; }
  const selected = store.scripts.find((item: ConfigScript): boolean => item.id === binding.scriptId);
  return selected === undefined ? undefined : `script:${selected.id}:${selected.revision}`;
}

async function changeScripts(filesDir: string, change: (store: ConfigScriptsSnapshot) => Promise<void>, eligible?: () => boolean):
  Promise<ConfigScriptsSnapshot> {
  return withProfileStorage<ConfigScriptsSnapshot>(filesDir, async (): Promise<ConfigScriptsSnapshot> => {
    const store = await readConfigScripts(filesDir);
    await change(store);
    const list = await readListAsync(filesDir);
    store.bindings = store.bindings.filter((binding: ConfigScriptBinding): boolean =>
      findProfile(list, binding.profile) !== undefined);
    const serialized = await taskpool.execute(encodeScripts, store, SCRIPT_STORE_LIMIT, SCRIPT_LIMIT) as string;
    await writeProfileText(scriptsPath(filesDir), serialized, eligible);
    return store;
  });
}

export function requireConfigScript(store: ConfigScriptsSnapshot, expected: ConfigScript): number {
  const index = store.scripts.findIndex((item: ConfigScript): boolean => item.id === expected.id);
  if (index < 0 || store.scripts[index].revision !== expected.revision) { throw new Error('script_conflict'); }
  return index;
}

function availableName(store: ConfigScriptsSnapshot, name: string, id: string): boolean {
  return !store.scripts.some((item: ConfigScript): boolean => item.id !== id && item.name === name);
}

function importName(store: ConfigScriptsSnapshot, raw: string): string {
  const name = raw.replace(new RegExp('\\.[^./]+$'), '').trim().slice(0, 64) || 'Script';
  let candidate = name;
  let suffix = 1;
  while (!availableName(store, candidate, '')) {
    const ending = `(${suffix++})`;
    candidate = name.slice(0, 64 - ending.length) + ending;
  }
  return candidate;
}

export function saveConfigScript(filesDir: string, expected: ConfigScript | undefined, name: string, source: string,
  url: string = '', imported: boolean = false, eligible?: () => boolean): Promise<ConfigScriptsSnapshot> {
  return changeScripts(filesDir, (store: ConfigScriptsSnapshot): Promise<void> => {
    const label = imported ? importName(store, name) : name.trim();
    if (label === '') { throw new Error('name_empty'); }
    if (label.length > 64) { throw new Error('name_long'); }
    const id = expected?.id ?? newId('js');
    if (!availableName(store, label, id)) { throw new Error('name_taken'); }
    const next: ConfigScript = { id: id, name: label, source: source, url: url, revision: newId('r'), updatedAt: Date.now() };
    if (expected === undefined) { store.scripts.push(next); }
    else { store.scripts[requireConfigScript(store, expected)] = next; }
    return Promise.resolve();
  }, eligible);
}

export function removeConfigScript(filesDir: string, expected: ConfigScript): Promise<ConfigScriptsSnapshot> {
  return changeScripts(filesDir, (store: ConfigScriptsSnapshot): Promise<void> => {
    store.scripts.splice(requireConfigScript(store, expected), 1);
    return Promise.resolve();
  });
}

export function reorderConfigScripts(filesDir: string, from: ConfigScript,
  to: ConfigScript): Promise<ConfigScriptsSnapshot> {
  return changeScripts(filesDir, (store: ConfigScriptsSnapshot): Promise<void> => {
    const source = requireConfigScript(store, from);
    const destination = requireConfigScript(store, to);
    const shifted = store.scripts.splice(source, 1)[0];
    store.scripts.splice(destination, 0, shifted);
    return Promise.resolve();
  });
}

export function saveScriptBinding(filesDir: string, expected: ConfigScriptBinding,
  next: ConfigScriptBinding): Promise<ConfigScriptsSnapshot> {
  return changeScripts(filesDir, async (store: ConfigScriptsSnapshot): Promise<void> => {
    const profile = findProfile(await readListAsync(filesDir), next.profile);
    if (profile === undefined || profile.type === 'custom') { throw new Error('script_conflict'); }
    const previous = scriptBinding(store, next.profile);
    if (previous.mode !== expected.mode || previous.scriptId !== expected.scriptId ||
      (next.scriptId !== '' && next.scriptId !== previous.scriptId &&
        !store.scripts.some((item: ConfigScript): boolean => item.id === next.scriptId))) {
      throw new Error('script_conflict');
    }
    store.bindings = store.bindings.filter((item: ConfigScriptBinding): boolean => item.profile !== next.profile);
    if (next.mode !== 'standard' || next.scriptId !== '') { store.bindings.push(next); }
  });
}

export async function readScriptText(path: string): Promise<string> {
  const file = await fs.open(path, fs.OpenMode.READ_ONLY);
  try {
    const size = (await fs.stat(file.fd)).size;
    if (size > SCRIPT_LIMIT) { throw new Error('script_size'); }
    const bytes = new Uint8Array(size + 1);
    let read = 0;
    while (read < bytes.byteLength) {
      const chunk = new ArrayBuffer(Math.min(65536, bytes.byteLength - read));
      const length = await fs.read(file.fd, chunk);
      if (length <= 0) { break; }
      bytes.set(new Uint8Array(chunk, 0, length), read);
      read += length;
    }
    if (read > SCRIPT_LIMIT) { throw new Error('script_size'); }
    if (read > size) { throw new Error('script_conflict'); }
    try {
      return new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes.subarray(0, read));
    } catch (error) { throw new Error('script_encoding'); }
  } finally { await fs.close(file); }
}

export function scriptUrlName(source: string): string {
  try { return decodeURIComponent(new urlKit.URL(source).pathname.split('/').filter((part: string): boolean => part !== '')
    .pop() ?? ''); } catch (error) { return ''; }
}

export function isScriptLoopback(source: string): boolean {
  return ['localhost', '127.0.0.1', '[::1]', '::1'].includes(hostOf(source.trim()).toLowerCase());
}

export async function downloadConfigScript(filesDir: string, downloader: Downloader, sourceUrl: string,
  existing?: ConfigScript, eligible: () => boolean = (): boolean => true): Promise<ConfigScriptsSnapshot> {
  const url = sourceUrl.trim();
  if (!validSubscriptionUrl(url)) { throw new Error('url_invalid'); }
  const key = existing?.id ?? newId('script-import');
  return withProfileTask<ConfigScriptsSnapshot>(filesDir, key, async (): Promise<ConfigScriptsSnapshot> => {
    if (existing !== undefined) { requireConfigScript(await readConfigScripts(filesDir), existing); }
    if (!eligible()) { throw new Error('canceled'); }
    await ensureProfilesDir(filesDir);
    const path = candidatePath(filesDir, key);
    try {
      const transport = isScriptLoopback(url) ? new DirectDownloader() : downloader;
      await transport.download(url, path, { canceled: (): boolean => !eligible(), maxBytes: SCRIPT_LIMIT });
      const text = await readScriptText(path);
      if (text.trim() === '') { throw new Error('script_empty'); }
      if (!eligible()) { throw new Error('canceled'); }
      return await saveConfigScript(filesDir, existing, existing?.name ?? scriptUrlName(url), text, url,
        existing === undefined, eligible);
    } finally { await removeProfileFile(path); }
  });
}
