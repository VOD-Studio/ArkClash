import { taskpool } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { DownloadRequestIdentity, Downloader } from './Download';
import {
  checkIconSetSnapshot, ICON_SET_MANIFEST_LIMIT, IconSetDownloadCommand, IconSetSnapshot, iconFileName,
  ImportedIconSet, makeIconSet, parseIconSetManifest, ProfileIconSet, validIconSetUrl
} from './IconSetModel';
import {
  candidatePath, ensureProfilesDir, newId, profilesDir, readOptionalText, removeProfileFile, withProfileStorage,
  writeProfileText
} from './Store';

const ICON_SET_STORE_LIMIT = 16 * 1024 * 1024;

@Concurrent
function decodeIconSetSnapshot(text: string): IconSetSnapshot {
  return checkIconSetSnapshot(JSON.parse(text) as IconSetSnapshot);
}

@Concurrent
function encodeIconSetSnapshot(snapshot: IconSetSnapshot): string {
  return JSON.stringify(checkIconSetSnapshot(snapshot));
}

@Concurrent
function parseIconSetFile(path: string): ImportedIconSet {
  return parseIconSetManifest(fs.readTextSync(path));
}

export function emptyIconSets(): IconSetSnapshot { return { revision: 'default', sets: [] }; }

function iconSetsPath(filesDir: string): string { return `${profilesDir(filesDir)}/icon-sets.json`; }

export async function readIconSets(filesDir: string): Promise<IconSetSnapshot> {
  const text = await readOptionalText(iconSetsPath(filesDir));
  return text === undefined ? emptyIconSets() : await taskpool.execute(decodeIconSetSnapshot, text) as IconSetSnapshot;
}

export function commitIconSets(filesDir: string, expectedRevision: string, items: ProfileIconSet[],
  revision: string = newId('r'), eligible?: () => boolean): Promise<IconSetSnapshot> {
  return withProfileStorage<IconSetSnapshot>(filesDir, async (): Promise<IconSetSnapshot> => {
    if ((await readIconSets(filesDir)).revision !== expectedRevision || revision === expectedRevision) {
      throw new Error('icon_set_conflict');
    }
    const next: IconSetSnapshot = { revision: revision, sets: items };
    const encoded = await taskpool.execute(encodeIconSetSnapshot, next) as string;
    if (encoded.length > ICON_SET_STORE_LIMIT) { throw new Error('icon_set_size'); }
    await writeProfileText(iconSetsPath(filesDir), encoded, eligible);
    return next;
  });
}

async function parseCandidate(path: string): Promise<ImportedIconSet> {
  const size = (await fs.stat(path)).size;
  if (size < 1 || size > ICON_SET_MANIFEST_LIMIT) { throw new Error('icon_set_size'); }
  try {
    return await taskpool.execute(parseIconSetFile, path) as ImportedIconSet;
  } catch (_error) { throw new Error('icon_set_invalid'); }
}

export async function importIconSetFile(filesDir: string, expected: IconSetSnapshot, uri: string,
  fileName: string): Promise<IconSetSnapshot> {
  await ensureProfilesDir(filesDir);
  const id = newId('is');
  const path = candidatePath(filesDir, id);
  try {
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = (await fs.stat(file.fd)).size;
      if (size < 1 || size > ICON_SET_MANIFEST_LIMIT) { throw new Error('icon_set_size'); }
      await fs.copyFile(file.fd, path);
    } finally { await fs.close(file); }
    const manifest = await parseCandidate(path);
    return await commitIconSets(filesDir, expected.revision, expected.sets.concat(makeIconSet(id, '', '', fileName, manifest)));
  } finally { await removeProfileFile(path); }
}

export async function downloadIconSet(filesDir: string, downloader: Downloader, command: IconSetDownloadCommand,
  eligible?: () => boolean): Promise<IconSetSnapshot> {
  if (typeof command.expectedRevision !== 'string' || typeof command.revision !== 'string' ||
    typeof command.id !== 'string' || typeof command.name !== 'string' || command.name.length > 80 ||
    !validIconSetUrl(command.url)) { throw new Error('icon_set_input'); }
  const snapshot = await readIconSets(filesDir);
  if (snapshot.revision !== command.expectedRevision || command.revision === snapshot.revision) {
    throw new Error('icon_set_conflict');
  }
  const items = snapshot.sets.slice();
  const bySource = items.findIndex((item: ProfileIconSet): boolean => item.url === command.url);
  const index = command.id === '' ? bySource : items.findIndex((item: ProfileIconSet): boolean => item.id === command.id);
  if ((command.id !== '' && index < 0) || (bySource >= 0 && bySource !== index)) {
    throw new Error('icon_set_conflict');
  }
  const existing = items[index];
  const id = existing?.id ?? newId('is');
  await ensureProfilesDir(filesDir);
  const path = candidatePath(filesDir, id);
  try {
    const identity: DownloadRequestIdentity = { canceled: (): boolean => eligible?.() === false,
      maxBytes: ICON_SET_MANIFEST_LIMIT };
    try { await downloader.download(command.url, path, identity); }
    catch (_error) { throw new Error('icon_set_download'); }
    const manifest = await parseCandidate(path);
    const entry = makeIconSet(id, command.name.trim() || existing?.name || '', command.url,
      iconFileName(command.url), manifest);
    if (index < 0) { items.push(entry); } else { items[index] = entry; }
    return await commitIconSets(filesDir, command.expectedRevision, items, command.revision, eligible);
  } finally { await removeProfileFile(path); }
}
