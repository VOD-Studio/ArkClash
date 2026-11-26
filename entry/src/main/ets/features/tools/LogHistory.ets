import { LogRecord } from '../../client/Logs';
import { RecordHistory } from './RecordStores';

export class LogListRow {
  readonly record: LogRecord;
  readonly order: number;
  readonly batch: number;
  readonly searchable: string;

  constructor(record: LogRecord, order: number, batch: number) {
    this.record = record;
    this.order = order;
    this.batch = batch;
    this.searchable = (record.level + ' ' + record.message).toLowerCase();
  }

  get id(): string { return this.record.id; }
  get key(): string { return this.record.id; }
}

export class LogHistory {
  readonly window: RecordHistory<LogListRow>;
  private order: number = 0;
  private pausedAt: number = 0;
  batch: number = 0;
  pending: number = 0;

  constructor(limit: number) { this.window = new RecordHistory<LogListRow>(limit, limit * 2); }

  clear(): void {
    this.window.clear();
    this.order = 0;
    this.pausedAt = 0;
    this.pending = 0;
  }

  setFollowing(following: boolean): void {
    if (following === this.window.following) { return; }
    this.pausedAt = this.order;
    this.window.setFollowing(following);
  }

  receive(records: LogRecord[], kind: string, newSession: boolean): void {
    const following = this.window.following;
    if (newSession) { this.clear(); }
    ++this.batch;
    const rows = records.map((record: LogRecord): LogListRow =>
      this.window.get(record.id) ?? new LogListRow(record, ++this.order, this.batch));
    if (kind === 'delta') {
      this.window.append(rows);
    } else {
      this.window.replace(rows, false);
      if (newSession) { this.setFollowing(following); }
    }
  }

  filter(query: string, level: string): LogListRow[] {
    const words = query.toLowerCase().trim().split(new RegExp('\\s+')).filter((word: string): boolean => word !== '');
    const source = this.window.values();
    const result: LogListRow[] = [];
    this.pending = 0;
    for (let i = source.length - 1; i >= 0; i--) {
      const row = source[i];
      if ((level !== '' && row.record.level !== level) ||
        !words.every((word: string): boolean => row.searchable.includes(word))) { continue; }
      result.push(row);
      if (!this.window.following && row.order > this.pausedAt && this.window.hasLatest(row.id)) { ++this.pending; }
    }
    return result;
  }
}
