import { LogRecord } from '../../client/Logs';
import { logClock } from './LogLabels';
import { RecordHistory } from './RecordStores';

export class LogListRow {
  readonly record: LogRecord;
  readonly order: number;
  readonly batch: number;
  readonly summary: string;
  readonly clock: string;
  private searchText?: string;

  constructor(record: LogRecord, order: number, batch: number, summary: string) {
    this.record = record;
    this.order = order;
    this.batch = batch;
    this.summary = summary;
    this.clock = logClock(record.time);
  }

  get id(): string { return this.record.id; }
  get key(): string { return this.record.id; }

  matches(terms: string[]): boolean {
    if (terms.length === 0) { return true; }
    if (this.searchText === undefined) {
      const parts: string[] = [this.record.level, this.record.message];
      if (this.record.tag !== undefined && this.record.tag !== '') { parts.push(this.record.tag); }
      if (this.record.target !== undefined && this.record.target !== '') { parts.push(this.record.target); }
      if (this.record.rule !== undefined && this.record.rule !== '') { parts.push(this.record.rule); }
      if (this.record.proxy !== undefined && this.record.proxy !== '') { parts.push(this.record.proxy); }
      if (this.record.source !== undefined && this.record.source !== '') { parts.push(this.record.source); }
      if (this.record.reason !== undefined && this.record.reason !== '') { parts.push(this.record.reason); }
      if (this.record.detail !== undefined && this.record.detail !== '') { parts.push(this.record.detail); }
      if (this.summary !== this.record.message) { parts.push(this.summary); }
      this.searchText = parts.join(' ').toLowerCase();
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

  levelCounts(): Record<string, number> {
    const counts: Record<string, number> = {};
    for (const row of this.window.values()) {
      const level = row.record.level;
      counts[level] = (counts[level] ?? 0) + 1;
    }
    return counts;
  }

  filter(query: string, level: string | string[]): LogListRow[] {
    if (query !== this.query) {
      this.query = query;
      const trimmed = query.toLowerCase().trim();
      this.terms = trimmed === '' ? [] : trimmed.split(new RegExp('\\s+'));
    }
    const levels: string[] = Array.isArray(level) ? level : (level === '' ? [] : [level]);
    let rows = this.window.values().reverse();
    if (levels.length > 0 || this.terms.length > 0) {
      rows = rows.filter((row: LogListRow): boolean =>
        (levels.length === 0 || levels.includes(row.record.level)) && row.matches(this.terms));
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
