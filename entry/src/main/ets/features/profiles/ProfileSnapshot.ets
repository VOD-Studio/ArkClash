import { findSubscription, intervalMinutes, ProfileList, ProfileRecord, readListAsync, readStateAsync,
  withProfileStorage } from '../../shared/profiles/Store';
import { ProfileItem } from './ProfileModels';

export interface ProfileLibrarySnapshot {
  list: ProfileList;
  items: ProfileItem[];
}

export async function readProfileSnapshot(filesDir: string): Promise<ProfileLibrarySnapshot> {
  return await withProfileStorage<ProfileLibrarySnapshot>(filesDir, async (): Promise<ProfileLibrarySnapshot> => {
    const list = await readListAsync(filesDir);
    const items = await Promise.all<ProfileItem>(list.profiles.map(async (record: ProfileRecord): Promise<ProfileItem> => {
      const item = new ProfileItem();
      const sub = findSubscription(list, record.subscription);
      item.id = record.id;
      item.name = record.name;
      item.nameEdited = record.nameEdited;
      item.subscription = record.subscription;
      item.url = sub?.url ?? '';
      item.autoUpdate = sub?.autoUpdate ?? false;
      item.intervalMinutes = sub !== undefined ? intervalMinutes(sub) : 1440;
      item.intervalHours = item.intervalMinutes / 60;
      item.contentRevision = record.contentRevision ?? '';
      item.updatedAt = record.updatedAt ?? 0;
      item.state = sub !== undefined ? await readStateAsync(filesDir, sub.id) : { updatedAt: item.updatedAt, failures: 0 };
      return item;
    }));
    return { list: list, items: items };
  });
}
