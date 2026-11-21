export type BackupScope = 'profiles' | 'all';
export type BackupPolicy = 'merge' | 'replace';
export type BackupDestination = 'local' | 'dav';
export type BackupPhase = 'idle' | 'snapshot' | 'pack' | 'transfer' | 'unpack' | 'validate' | 'commit' | 'apply';

export interface BackupDav {
  address: string;
  username: string;
  password: string;
  fileName: string;
}

export interface BackupSettings {
  dav?: BackupDav;
  policy: BackupPolicy;
}

export interface BackupPlan {
  current: string;
  changes: boolean;
  removed: number;
  removedNames?: string[];
  profiles: number;
  revision: string;
  settings: boolean;
}

export function backupDateName(date: Date): string {
  const month = (date.getMonth() + 1).toString().padStart(2, '0');
  const day = date.getDate().toString().padStart(2, '0');
  return `ArkClash_backup_${date.getFullYear()}-${month}-${day}.zip`;
}

export function emptyBackupDav(): BackupDav {
  return { address: '', username: '', password: '', fileName: 'backup.zip' };
}
