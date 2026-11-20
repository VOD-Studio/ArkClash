import { installConfigSource } from '../shared/profiles/InstallConfig';

@ObservedV2
export class ProfileInstallInbox {
  @Trace pending: string = '';
  private active: string = '';

  offer(link: string): void {
    const source = installConfigSource(link);
    if (source !== undefined && source !== this.active && source !== this.pending) { this.pending = source; }
  }

  take(): string {
    this.active = this.pending;
    this.pending = '';
    return this.active;
  }

  finish(): void { this.active = ''; }
}
