import { DEFAULT_INTERVAL_MINUTES, SubscriptionState } from '../../shared/profiles/Store';

@ObservedV2
export class ProfileItem {
  @Trace id: string = '';
  @Trace name: string = '';
  @Trace nameEdited: boolean = false;
  @Trace subscription: string = '';
  @Trace type: string = '';
  @Trace url: string = '';
  @Trace autoUpdate: boolean = true;
  @Trace intervalMinutes: number = DEFAULT_INTERVAL_MINUTES;
  @Trace intervalHours: number = DEFAULT_INTERVAL_MINUTES / 60;
  @Trace state: SubscriptionState = { updatedAt: 0, failures: 0 };
  @Trace updating: boolean = false;
  @Trace contentRevision: string = '';
  @Trace updatedAt: number = 0;

  get isSubscription(): boolean {
    return this.subscription !== '';
  }
}

export interface ProfileEdit {
  name: string;
  url: string;
  autoUpdate: boolean;
  intervalMinutes?: number;
  intervalHours?: number;
  content?: string;
  baseContentRevision?: string;
  baseName?: string;
  baseUrl?: string;
}

export interface ProfileBatchFailure {
  id: string;
  name: string;
  error: string;
  line?: number;
}

export interface ProfileBatchResult {
  total: number;
  succeeded: number;
  skipped: number;
  failures: ProfileBatchFailure[];
}

export interface ProfileLinkEntry {
  source: string;
  line: number;
}

export interface ProfileLinkInput {
  entries: ProfileLinkEntry[];
  skipped: number;
  errors: number[];
}

export function mergeProfileItem(previous: ProfileItem | undefined, fresh: ProfileItem): ProfileItem {
  if (previous === undefined) { return fresh; }
  previous.name = fresh.name;
  previous.nameEdited = fresh.nameEdited;
  previous.subscription = fresh.subscription;
  previous.type = fresh.type;
  previous.url = fresh.url;
  previous.autoUpdate = fresh.autoUpdate;
  previous.intervalMinutes = fresh.intervalMinutes;
  previous.intervalHours = fresh.intervalHours;
  previous.state = fresh.state;
  previous.contentRevision = fresh.contentRevision;
  previous.updatedAt = fresh.updatedAt;
  return previous;
}
