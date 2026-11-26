import { LogRecord } from '../../client/Logs';
import { RecordHistory } from './RecordStores';

export class LogListRow {
  readonly record: LogRecord;
  readonly order: number;
  readonly batch: number;
  readonly summary: string;
  private searchText?: string;

  constructor(record: LogRecord, order: number, batch: number, summary: string) {
    this.record = record;
    this.order = order;
    this.batch = batch;
    this.summary = summary;
  }

  get id(): string { return this.record.id; }
  get key(): string { return this.record.id; }

  matches(terms: string[]): boolean {
    if (terms.length === 0) { return true; }
    if (this.searchText === undefined) {
      this.searchText = (this.record.level + ' ' + this.record.message +
        (this.summary === this.record.message ? '' : ' ' + this.summary)).toLowerCase();
    }
    for (const term of terms) {
      if (!this.searchText.includes(term)) { return false; }
    }
    return true;
  }
}

export class LogHistory {
  readonly window: RecordHistory<LogListRow>;
  private order: number = 0;
  private pausedAt: number = 0;
  private query: string = '';
  private terms: string[] = [];
  private readonly describe: (record: LogRecord) => string;
  batch: number = 0;
  pending: number = 0;

  constructor(limit: number, describe: (record: LogRecord) => string) {
    this.window = new RecordHistory<LogListRow>(limit, limit * 2);
    this.describe = describe;
  }

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
      this.window.get(record.id) ?? new LogListRow(record, ++this.order, this.batch, this.describe(record)));
    if (kind === 'delta') {
      this.window.append(rows);
    } else {
      this.window.replace(rows, false);
      if (newSession) { this.setFollowing(following); }
    }
  }

  filter(query: string, level: string): LogListRow[] {
    if (query !== this.query) {
      this.query = query;
      const trimmed = query.toLowerCase().trim();
      this.terms = trimmed === '' ? [] : trimmed.split(new RegExp('\\s+'));
    }
    let rows = this.window.values().reverse();
    if (level !== '' || this.terms.length > 0) {
      rows = rows.filter((row: LogListRow): boolean =>
        (level === '' || row.record.level === level) && row.matches(this.terms));
    }
    this.pending = 0;
    if (!this.window.following) {
      for (const row of rows) {
        if (row.order <= this.pausedAt) { break; }
        if (this.window.hasLatest(row.id)) { ++this.pending; }
      }
    }
    return rows;
  }
}
