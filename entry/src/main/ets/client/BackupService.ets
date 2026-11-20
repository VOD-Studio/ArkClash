import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import storeNative from 'libarkstore.so';
import {
  BackupDav, BackupDestination, BackupPhase, BackupPlan, BackupPolicy, BackupScope, BackupSettings
} from '../shared/backup/BackupModel';
import { readRuntime } from '../shared/Runtime';
import { analyze } from '../shared/profiles/Summary';
import { newId, profileDataPath, readListAsync, readOptionalText, readProfileListFile, withProfileStorage,
  writeProfileText } from '../shared/profiles/Store';
import { applyBackupPreferences, exportBackupPreferences, exportBackupViews, planBackupViews,
  validateBackupPreferences } from './BackupPreferences';
import { connection } from './Connection';
import { call } from './Controller';
import { readCoreHostStatus } from './CoreClient';

const MAX_ARCHIVE = 256 * 1024 * 1024;
const BUFFER_SIZE = 1024 * 1024;
const DAV_TIMEOUT = 280000;

interface BackupStoreRequest {
  action: string;
  home: string;
  work: string;
  all?: boolean;
  replace?: boolean;
  revision?: string;
  dav?: BackupDav;
}

interface BackupStoreReply {
  error?: string;
  revision?: string;
  plan?: BackupPlan;
}

interface BackupDavRequest {
  bootId: string;
  work: string;
  action: string;
  dav: BackupDav;
}

interface BackupApplyRequest {
  bootId: string;
  profile: string;
  revision: string;
  mode: string;
  allowLan?: boolean;
}

export interface BackupControl {
  phase: (current: BackupPhase) => void;
  canceled: () => boolean;
}

export interface BackupRestoreOutcome {
  plan?: BackupPlan;
  canceled: boolean;
  pendingApply: boolean;
}

function checkCanceled(control: BackupControl): void {
  if (control.canceled()) { throw new Error('backup_canceled'); }
}

async function backupNative(request: BackupStoreRequest): Promise<BackupStoreReply> {
  const execution: Promise<string> = storeNative.run(JSON.stringify(request));
  const result = JSON.parse(await execution) as BackupStoreReply;
  if (result.error !== undefined) {
    hilog.warn(0xD000, 'ArkClashBackup', '存储操作 %{public}s 未完成 %{public}s', request.action, result.error);
    throw new Error(result.error);
  }
  return result;
}

class BackupWorkspace {
  readonly home: string;
  readonly id: string = newId('backup-');
  constructor(home: string) { this.home = home; }

  directory(): string { return `${this.home}/${this.id}`; }
  file(): string { return `${this.directory()}/archive.zip`; }
  async open(): Promise<void> { await fs.mkdir(this.directory()); }
  async dispose(): Promise<void> { await fs.rmdir(this.directory()).catch((): void => {}); }

  run(action: string, all: boolean = false, replace: boolean = false,
    revision: string = ''): Promise<BackupStoreReply> {
    return backupNative({ action: action, home: this.home, work: this.id, all: all, replace: replace, revision: revision });
  }

  async dav(context: common.UIAbilityContext, action: string, dav: BackupDav): Promise<void> {
    const host = await readCoreHostStatus(context);
    if (host.state === 'running' && host.status !== undefined) {
      const request: BackupDavRequest = { bootId: host.status.bootId, work: this.id, action: action, dav: dav };
      await call(this.home, http.RequestMethod.POST, '/arkclash/backup/dav', JSON.stringify(request), DAV_TIMEOUT);
      return;
    }
    if (host.state !== 'stopped' && !(await waitingForFirstHost(this.home))) {
      throw new Error('backup_dav_network');
    }
    await backupNative({ action: action, home: this.home, work: this.id, dav: dav });
  }
}

async function waitingForFirstHost(home: string): Promise<boolean> {
  // 授权框或预热等待期间，扩展必须先写实例证据才能接管流量。
  const runtime = await readRuntime(home);
  return !connection.busy && !connection.connected && runtime?.vpnIntent === 'stopped' &&
    !(await fs.access(`${home}/runtime-instance.json`));
}

export async function readBackupSettings(home: string): Promise<BackupSettings> {
  const path = await profileDataPath(home, 'backup-settings.json');
  const text = await readOptionalText(path);
  return text === undefined ? { policy: 'merge' } : decodeBackupSettings(text);
}

function decodeBackupSettings(text: string): BackupSettings {
  const settings = JSON.parse(text) as BackupSettings;
  if (settings === null || (settings.policy !== 'merge' && settings.policy !== 'replace') ||
    settings.dav !== undefined && !validBackupDav(settings.dav)) {
    throw new Error('backup_invalid');
  }
  return settings;
}

export async function writeBackupSettings(home: string, settings: BackupSettings): Promise<void> {
  await withProfileStorage<void>(home, async (): Promise<void> => {
    const path = await profileDataPath(home, 'backup-settings.json');
    await writeProfileText(path, JSON.stringify(settings));
  });
}

export function validBackupDav(dav: BackupDav): boolean {
  if (dav === null || typeof dav.address !== 'string' || typeof dav.username !== 'string' ||
    typeof dav.password !== 'string' || typeof dav.fileName !== 'string') { return false; }
  return /^https?:\/\/[^\s]+$/i.test(dav.address) && dav.address.length <= 2048 &&
    dav.username.length > 0 && dav.username.length <= 128 && !/[:\r\n]/.test(dav.username) &&
    dav.password.length > 0 && dav.password.length <= 4096 &&
    dav.fileName.length > 0 && dav.fileName.length <= 255 && dav.fileName !== '.' && dav.fileName !== '..' &&
    !/[/\\:*?"<>|\r\n]/.test(dav.fileName);
}

export async function probeBackupDav(context: common.UIAbilityContext, dav: BackupDav): Promise<void> {
  const space = new BackupWorkspace(context.filesDir);
  await space.open();
  try { await space.dav(context, 'probe', dav); } finally { await space.dispose(); }
}

export async function chooseBackupFile(context: common.UIAbilityContext): Promise<string | undefined> {
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  options.fileSuffixFilters = ['ZIP|.zip'];
  return (await new picker.DocumentViewPicker(context).select(options))[0];
}

export async function chooseBackupTarget(context: common.UIAbilityContext, name: string): Promise<string | undefined> {
  const options = new picker.DocumentSaveOptions();
  options.newFileNames = [name];
  options.fileSuffixChoices = ['ZIP|.zip'];
  return (await new picker.DocumentViewPicker(context).save(options))[0];
}

async function copyBackupFile(source: string, target: string, control: BackupControl): Promise<void> {
  const input = await fs.open(source, fs.OpenMode.READ_ONLY);
  try {
    if ((await fs.stat(input.fd)).size >= MAX_ARCHIVE) { throw new Error('backup_limit'); }
    const output = await fs.open(target, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const buffer = new ArrayBuffer(BUFFER_SIZE);
      let total = 0;
      while (true) {
        checkCanceled(control);
        const size = await fs.read(input.fd, buffer);
        if (size === 0) { break; }
        total += size;
        if (total >= MAX_ARCHIVE) { throw new Error('backup_limit'); }
        if (await fs.write(output.fd, buffer, { length: size }) !== size) { throw new Error('backup_io'); }
      }
      await fs.fsync(output.fd);
    } finally {
      await fs.close(output);
    }
  } finally {
    await fs.close(input);
  }
}

async function saveBackupFile(source: string, target: string): Promise<void> {
  const input = await fs.open(source, fs.OpenMode.READ_ONLY);
  try {
    const output = await fs.open(target, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { await fs.copyFile(input.fd, output.fd); }
    finally { await fs.close(output); }
  } finally { await fs.close(input); }
}

export async function exportBackup(context: common.UIAbilityContext, destination: BackupDestination,
  scope: BackupScope, dav: BackupDav | undefined, control: BackupControl,
  chooseTarget: () => Promise<string | undefined>): Promise<boolean> {
  const space = new BackupWorkspace(context.filesDir);
  await space.open();
  try {
    control.phase('snapshot');
    const snapshot = await withProfileStorage<BackupStoreReply>(space.home,
      (): Promise<BackupStoreReply> => space.run('snapshot', scope === 'all'));
    const revision = snapshot.revision ?? '';
    await exportBackupViews(context, `${space.directory()}/previous`, revision);
    if (scope === 'all') {
      await exportBackupPreferences(context, `${space.directory()}/previous/portable-preferences.json`, revision);
    }
    checkCanceled(control);
    control.phase('pack');
    await space.run('pack', false, false, revision);
    checkCanceled(control);
    if (destination === 'dav' && dav !== undefined) {
      control.phase('transfer');
      await space.dav(context, 'upload', dav);
    } else {
      control.phase('idle');
      const target = await chooseTarget();
      if (target === undefined) { return false; }
      control.phase('transfer');
      await saveBackupFile(space.file(), target);
    }
    return true;
  } finally {
    await space.dispose();
  }
}

export async function restoreBackup(context: common.UIAbilityContext, destination: BackupDestination,
  scope: BackupScope, policy: BackupPolicy, source: string, dav: BackupDav | undefined, control: BackupControl,
  confirm: (plan: BackupPlan) => Promise<boolean>): Promise<BackupRestoreOutcome> {
  const space = new BackupWorkspace(context.filesDir);
  await space.open();
  try {
    control.phase('transfer');
    if (destination === 'dav' && dav !== undefined) {
      await space.dav(context, 'download', dav);
    } else {
      await copyBackupFile(source, space.file(), control);
    }
    checkCanceled(control);
    control.phase('unpack');
    await space.run('unpack');
    checkCanceled(control);
    for (let attempt = 0; attempt < 3; attempt++) {
      control.phase('validate');
      await withProfileStorage<BackupStoreReply>(space.home, (): Promise<BackupStoreReply> => space.run('snapshot', true));
      const planned = await space.run('plan', scope === 'all', policy === 'replace');
      const plan = planned.plan;
      if (plan === undefined) { throw new Error('backup_invalid'); }
      if (!plan.changes && !plan.settings) { return { plan: plan, canceled: false, pendingApply: false }; }
      const working = space.directory();
      await validateBackupProfiles(`${working}/next`, control);
      if (plan.settings) {
        await validateBackupPreferences(`${working}/next`);
        const path = `${working}/next/backup-settings.json`;
        const text = await readOptionalText(path);
        if (text !== undefined) { decodeBackupSettings(text); }
      }
      if (plan.changes) { await planBackupViews(`${working}/imported`, `${working}/next`, plan.revision); }
      await space.run('seal', false, false, plan.revision);
      if (policy === 'replace' && plan.removed > 0 && !(await confirm(plan))) {
        return { canceled: true, pendingApply: false };
      }
      checkCanceled(control);
      try {
        await withProfileStorage<void>(space.home, async (): Promise<void> => {
          await space.run('prepare');
          checkCanceled(control);
          control.phase('commit');
          await space.run('commit');
        });
      } catch (error) {
        if ((error as Error).message !== 'backup_changed' || attempt === 2) { throw error as Error; }
        for (const dir of ['previous', 'fresh', 'next']) {
          await fs.rmdir(`${space.directory()}/${dir}`).catch((): void => {});
        }
        continue;
      }
      control.phase('apply');
      const applied = await applySavedBackup(context).then((): boolean => true, (): boolean => false);
      return { plan: plan, canceled: false, pendingApply: !applied };
    }
    throw new Error('backup_changed');
  } finally {
    await space.dispose();
  }
}

async function validateBackupProfiles(directory: string, control: BackupControl): Promise<void> {
  const list = await readProfileListFile(`${directory}/list.json`);
  for (const item of list.profiles) {
    checkCanceled(control);
    const result = await analyze(`${directory}/${item.id}.yaml`);
    if (result.error !== '') { throw new Error('backup_invalid'); }
    await writeProfileText(`${directory}/${item.id}.summary.json`, result.summary);
  }
}

export async function applySavedBackup(context: common.UIAbilityContext): Promise<void> {
  await applyBackupPreferences(context);
  connection.restore(context);
  const list = await readListAsync(context.filesDir);
  let host = await readCoreHostStatus(context);
  if (host.state === 'stopped' || host.state === 'unknown' && await waitingForFirstHost(context.filesDir)) { return; }
  if (host.state !== 'running' || host.status === undefined) { throw new Error('backup_apply'); }
  if (list.current === '' && (host.status.tunAttached || host.status.vpnCreated || host.status.listenersOpen)) {
    await connection.disconnect(context);
    host = await readCoreHostStatus(context);
  }
  if (host.state !== 'running' || host.status === undefined) { throw new Error('backup_apply'); }
  const request: BackupApplyRequest = { bootId: host.status.bootId, profile: list.current, revision: list.revision ?? '',
    mode: connection.mode, allowLan: connection.allowLan };
  await call(context.filesDir, http.RequestMethod.POST, '/arkclash/backup/apply', JSON.stringify(request), 90000);
}
