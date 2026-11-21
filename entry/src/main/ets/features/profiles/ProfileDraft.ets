import { ProfileItem } from './ProfileModels';

@ObservedV2
export class ProfileDraft {
  @Trace name: string = '';
  @Trace link: string = '';
  @Trace ageSecretKey: string = '';
  @Trace autoUpdate: boolean = true;
  @Trace interval: string = '1440';
  @Trace content: string | undefined = undefined;
  @Trace error: string = '';
  @Trace saving: boolean = false;
  id: string = '';
  subscription: boolean = false;
  baseName: string = '';
  baseLink: string = '';
  baseAgeSecretKey: string = '';
  baseAuto: boolean = true;
  baseInterval: string = '1440';
  baseContentRevision: string = '';
  save: (() => Promise<boolean>) | undefined = undefined;

  constructor(item: ProfileItem) {
    this.id = item.id;
    this.subscription = item.isSubscription;
    this.name = item.name;
    this.link = item.url;
    this.ageSecretKey = item.ageSecretKey;
    this.autoUpdate = item.autoUpdate;
    this.interval = `${item.intervalMinutes}`;
    this.baseContentRevision = item.contentRevision;
    this.saved();
  }

  dirty(): boolean {
    return this.name !== this.baseName || this.link !== this.baseLink || this.autoUpdate !== this.baseAuto ||
      this.ageSecretKey !== this.baseAgeSecretKey || this.interval !== this.baseInterval || this.content !== undefined;
  }

  saved(): void {
    this.baseName = this.name;
    this.baseLink = this.link;
    this.baseAgeSecretKey = this.ageSecretKey;
    this.baseAuto = this.autoUpdate;
    this.baseInterval = this.interval;
    this.content = undefined;
  }
}
