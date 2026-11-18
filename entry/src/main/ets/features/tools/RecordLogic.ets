import { DiagnosticConnection, DiagnosticDnsRecord, DiagnosticMetadata } from '../../client/Diagnostics';

export type RequestFeed = 'live' | 'recent';
export type RecordGrouping = 'none' | 'host' | 'rule' | 'exit';
export type RecordView = 'requests' | 'connections' | 'dns';
export type RecordFacets = Record<string, string[]>;

export interface RecordSort {
  column: string;
  direction: '' | 'asc' | 'desc';
}

export interface ConnectionRecordView {
  key: string;
  connection: DiagnosticConnection;
  uploadSpeed: number;
  downloadSpeed: number;
  rankSpeed: number;
  duration: number;
}

export interface RecordGroup {
  key: string;
  title: string;
  items: ConnectionRecordView[];
}

export interface RecordColumn {
  id: string;
  width: number;
  flex: number;
  numeric: boolean;
  resizable: boolean;
  descending: boolean;
}

export function diagnosticEndpoint(address: string, port: string): string {
  if (address === '') {
    return '';
  }
  const host = address.includes(':') && !address.startsWith('[') ? `[${address}]` : address;
  return port === '' ? host : `${host}:${port}`;
}

export function connectionRule(record: DiagnosticConnection): string {
  return record.rulePayload === '' ? record.rule :
    (record.rule === '' ? record.rulePayload : `${record.rule}(${record.rulePayload})`);
}

function queryTerms(query: string): string[] {
  return query.trim().toLowerCase().split(new RegExp('\\s+')).filter((part: string): boolean => part !== '');
}

function matchesQuery(fields: string[], terms: string[]): boolean {
  const searchable = fields.join('\n').toLowerCase();
  return terms.every((term: string): boolean => searchable.includes(term));
}

function connectionFields(record: DiagnosticConnection): string[] {
  const m = record.metadata;
  return [m.network, m.type, m.host, m.sourceIP, m.sourcePort, m.destinationIP, m.destinationPort,
    m.sourceIPASN, m.destinationIPASN, m.remoteDestination, m.dnsMode, m.specialProxy, m.specialRules,
    m.sniffHost, record.rule, record.rulePayload, ...m.sourceGeoIP, ...m.destinationGeoIP,
    ...record.chains, ...record.providerChains];
}

function connectionFacet(record: DiagnosticConnection, field: string): string[] {
  if (field === 'network') {
    return [record.metadata.network];
  }
  if (field === 'rule') {
    return [record.rule];
  }
  return field === 'proxy' ? record.chains : [];
}

function dnsFacet(record: DiagnosticDnsRecord, field: string): string[] {
  switch (field) {
    case 'type': return [record.type];
    case 'initiator': return [record.initiator];
    case 'cache': return [record.cached ? 'true' : 'false'];
    case 'rcode': return [record.rcode];
    default: return [];
  }
}

function hasSelected(values: string[], selected: string[]): boolean {
  return selected.length === 0 || values.some((entry: string): boolean => selected.includes(entry));
}

export function filterConnections(records: ConnectionRecordView[], query: string,
  facets: RecordFacets): ConnectionRecordView[] {
  const terms = queryTerms(query);
  const fields = Object.keys(facets);
  return records.filter((row: ConnectionRecordView): boolean =>
    (terms.length === 0 || matchesQuery(connectionFields(row.connection), terms)) && fields.every((field: string): boolean =>
      hasSelected(connectionFacet(row.connection, field), facets[field] ?? [])));
}

export function filterDns(records: DiagnosticDnsRecord[], query: string,
  facets: RecordFacets): DiagnosticDnsRecord[] {
  const terms = queryTerms(query);
  const fields = Object.keys(facets);
  return records.filter((row: DiagnosticDnsRecord): boolean =>
    (terms.length === 0 || matchesQuery([row.domain, row.type, row.initiator, row.rcode, row.upstream, row.error, ...row.answers], terms)) &&
      fields.every((field: string): boolean => hasSelected(dnsFacet(row, field), facets[field] ?? [])));
}

interface RecordFacetCount {
  text: string;
  count: number;
  order: number;
}

function countFacetOption(counts: Map<string, RecordFacetCount>, text: string): void {
  if (text === '') { return; }
  const previous = counts.get(text);
  if (previous === undefined) {
    counts.set(text, { text: text, count: 1, order: counts.size });
  } else {
    previous.count++;
  }
}

function rankedFacetOptions(counts: Map<string, RecordFacetCount>, selected: string[]): string[] {
  const ranked: RecordFacetCount[] = [];
  counts.forEach((entry: RecordFacetCount): void => { ranked.push(entry); });
  ranked.sort((a: RecordFacetCount, b: RecordFacetCount): number => b.count - a.count || a.order - b.order);
  const result = ranked.slice(0, 12).map<string>((entry: RecordFacetCount): string => entry.text);
  for (const text of selected) {
    if (!result.includes(text)) {
      result.push(text);
    }
  }
  return result;
}

function networkFacetOrder(value: string): number {
  return value === 'tcp' ? 0 : value === 'udp' ? 1 : 2;
}

export function connectionFacetOptions(records: Iterable<ConnectionRecordView>, field: string,
  selected: string[]): string[] {
  const counts = new Map<string, RecordFacetCount>();
  for (const row of records) {
    if (field === 'network') {
      countFacetOption(counts, row.connection.metadata.network);
    } else if (field === 'rule') {
      countFacetOption(counts, row.connection.rule);
    } else if (field === 'proxy') {
      for (const proxy of new Set<string>(row.connection.chains)) { countFacetOption(counts, proxy); }
    }
  }
  return rankedFacetOptions(counts, selected).sort((a: string, b: string): number => {
    if (field === 'network') {
      const order = networkFacetOrder(a) - networkFacetOrder(b);
      if (order !== 0) { return order; }
    }
    const left = a.toLowerCase();
    const right = b.toLowerCase();
    return left < right ? -1 : left > right ? 1 : 0;
  });
}

export function dnsFacetOptions(records: DiagnosticDnsRecord[], field: string, selected: string[]): string[] {
  const counts = new Map<string, RecordFacetCount>();
  for (const row of records) {
    for (const text of new Set<string>(dnsFacet(row, field))) { countFacetOption(counts, text); }
  }
  return rankedFacetOptions(counts, selected);
}

export function groupConnections(records: ConnectionRecordView[], grouping: RecordGrouping): RecordGroup[] {
  const result: RecordGroup[] = [];
  const groups = new Map<string, RecordGroup>();
  for (const row of records) {
    let title = '';
    switch (grouping) {
      case 'host': title = row.connection.metadata.host || row.connection.metadata.destinationIP; break;
      case 'rule': title = connectionRule(row.connection); break;
      case 'exit': title = row.connection.chains[0] ?? ''; break;
    }
    const key = `${grouping}:${title}`;
    let group = groups.get(key);
    if (group === undefined) {
      group = { key: key, title: title, items: [] };
      groups.set(key, group);
      result.push(group);
    }
    group.items.push(row);
  }
  return result;
}

export function nextRecordSort(sort: RecordSort, column: string, descending: boolean): RecordSort {
  const first = descending ? 'desc' : 'asc';
  if (sort.column !== column || sort.direction === '') {
    return { column: column, direction: first };
  }
  if (sort.direction === first) {
    return { column: column, direction: descending ? 'asc' : 'desc' };
  }
  return { column: '', direction: '' };
}

function compareText(a: string, b: string): number {
  const left = a.toLowerCase();
  const right = b.toLowerCase();
  return left < right ? -1 : (left > right ? 1 : 0);
}

function connectionSortValue(row: ConnectionRecordView, field: string): string | number {
  const record = row.connection;
  switch (field) {
    case 'time': return Date.parse(record.start) || 0;
    case 'target': return record.metadata.host || record.metadata.destinationIP;
    case 'protocol': return record.metadata.network;
    case 'rule': return connectionRule(record);
    case 'exit': return record.chains[0] ?? '';
    case 'traffic': return record.upload + record.download;
    case 'upload': return record.upload;
    case 'download': return record.download;
    case 'uploadSpeed': return row.uploadSpeed;
    case 'downloadSpeed': return row.downloadSpeed;
    case 'duration': return row.duration;
    default: return '';
  }
}

function dnsSortValue(record: DiagnosticDnsRecord, field: string): string | number {
  switch (field) {
    case 'time': return Date.parse(record.time) || 0;
    case 'domain': return record.domain;
    case 'type': return record.type;
    case 'initiator': return record.initiator;
    case 'result': return record.error || record.answers.join(', ') || record.rcode;
    case 'elapsed': return record.delay;
    case 'upstream': return record.upstream;
    default: return '';
  }
}

function compareRecordValue(a: string | number, b: string | number): number {
  return typeof a === 'number' && typeof b === 'number' ? a - b : compareText(`${a}`, `${b}`);
}

export function sortConnections(records: ConnectionRecordView[], sort: RecordSort): ConnectionRecordView[] {
  const result = records.slice();
  if (sort.column === '' || sort.direction === '') {
    return result;
  }
  const positions = new Map<string, number>();
  records.forEach((row: ConnectionRecordView, index: number): void => { positions.set(row.key, index); });
  const direction = sort.direction === 'desc' ? -1 : 1;
  result.sort((a: ConnectionRecordView, b: ConnectionRecordView): number =>
    compareRecordValue(connectionSortValue(a, sort.column), connectionSortValue(b, sort.column)) * direction ||
      (positions.get(a.key) ?? 0) - (positions.get(b.key) ?? 0));
  return result;
}

export function sortDns(records: DiagnosticDnsRecord[], sort: RecordSort): DiagnosticDnsRecord[] {
  const result = records.slice();
  if (sort.column === '' || sort.direction === '') {
    return result;
  }
  const positions = new Map<string, number>();
  records.forEach((row: DiagnosticDnsRecord, index: number): void => { positions.set(row.id, index); });
  const direction = sort.direction === 'desc' ? -1 : 1;
  result.sort((a: DiagnosticDnsRecord, b: DiagnosticDnsRecord): number =>
    compareRecordValue(dnsSortValue(a, sort.column), dnsSortValue(b, sort.column)) * direction ||
      (positions.get(a.id) ?? 0) - (positions.get(b.id) ?? 0));
  return result;
}

interface RecordSpeedSample {
  upload: number;
  download: number;
  at: number;
  uploadSpeed: number;
  downloadSpeed: number;
  rankSpeed: number;
}

function sameStrings(a: string[], b: string[]): boolean {
  return a === b || (a.length === b.length && a.every((entry: string, index: number): boolean => entry === b[index]));
}

function sameMetadata(a: DiagnosticMetadata, b: DiagnosticMetadata): boolean {
  return a === b || (a.network === b.network && a.type === b.type && a.sourceIP === b.sourceIP &&
    a.sourcePort === b.sourcePort && a.destinationIP === b.destinationIP && a.destinationPort === b.destinationPort &&
    a.host === b.host && a.dnsMode === b.dnsMode && a.remoteDestination === b.remoteDestination &&
    a.sourceIPASN === b.sourceIPASN && a.destinationIPASN === b.destinationIPASN && a.specialProxy === b.specialProxy &&
    a.specialRules === b.specialRules && a.sniffHost === b.sniffHost && sameStrings(a.sourceGeoIP, b.sourceGeoIP) &&
    sameStrings(a.destinationGeoIP, b.destinationGeoIP));
}

function sameConnection(a: DiagnosticConnection, b: DiagnosticConnection): boolean {
  return a === b || (a.id === b.id && a.start === b.start && a.upload === b.upload && a.download === b.download &&
    a.rule === b.rule && a.rulePayload === b.rulePayload && sameMetadata(a.metadata, b.metadata) &&
    sameStrings(a.chains, b.chains) && sameStrings(a.providerChains, b.providerChains));
}

function speedBucket(speed: number): number {
  return speed < 1 ? 0 : Math.floor(Math.log(speed) / Math.LN2) + 1;
}

export class TrackerSpeedRanker {
  private samples: Map<string, RecordSpeedSample> = new Map<string, RecordSpeedSample>();
  private positions: Map<string, number> = new Map<string, number>();
  private ranked: Map<string, ConnectionRecordView> = new Map<string, ConnectionRecordView>();

  reset(): void {
    this.samples.clear();
    this.positions.clear();
    this.ranked.clear();
  }

  private sample(record: DiagnosticConnection, sampledAt: number): RecordSpeedSample {
    const previous = this.samples.get(record.id);
    if (previous === undefined) {
      return { upload: record.upload, download: record.download, at: sampledAt,
        uploadSpeed: 0, downloadSpeed: 0, rankSpeed: 0 };
    }
    const elapsed = sampledAt - previous.at;
    if (elapsed < 500) {
      return previous;
    }
    const seconds = elapsed / 1000;
    const uploadSpeed = Math.max(0, record.upload - previous.upload) / seconds;
    const downloadSpeed = Math.max(0, record.download - previous.download) / seconds;
    const smoothed = previous.rankSpeed + (uploadSpeed + downloadSpeed - previous.rankSpeed) * 0.5;
    return { upload: record.upload, download: record.download, at: sampledAt,
      uploadSpeed: Math.round(uploadSpeed), downloadSpeed: Math.round(downloadSpeed),
      rankSpeed: smoothed < 1 ? 0 : smoothed };
  }

  rank(records: DiagnosticConnection[], sampledAt: number): ConnectionRecordView[] {
    const samples = new Map<string, RecordSpeedSample>();
    const ranked: ConnectionRecordView[] = [];
    for (const record of records) {
      const sample = this.sample(record, sampledAt);
      samples.set(record.id, sample);
      const parsedStart = Date.parse(record.start);
      const duration = Math.max(0, sampledAt - (Number.isFinite(parsedStart) ? parsedStart : sampledAt));
      const previous = this.ranked.get(record.id);
      if (previous !== undefined && sameConnection(previous.connection, record) &&
        previous.uploadSpeed === sample.uploadSpeed && previous.downloadSpeed === sample.downloadSpeed &&
        previous.rankSpeed === sample.rankSpeed && previous.duration === duration) {
        ranked.push(previous);
      } else {
        ranked.push({ key: record.id, connection: record, uploadSpeed: sample.uploadSpeed,
          downloadSpeed: sample.downloadSpeed, rankSpeed: sample.rankSpeed, duration: duration });
      }
    }
    ranked.sort((a: ConnectionRecordView, b: ConnectionRecordView): number => {
      const bucketA = speedBucket(a.rankSpeed);
      const bucket = speedBucket(b.rankSpeed) - bucketA;
      if (bucket !== 0) {
        return bucket;
      }
      if (bucketA > 0) {
        const position = (this.positions.get(a.key) ?? records.length) -
          (this.positions.get(b.key) ?? records.length);
        if (position !== 0) {
          return position;
        }
      }
      const traffic = b.connection.upload + b.connection.download - a.connection.upload - a.connection.download;
      const start = (Date.parse(b.connection.start) || 0) - (Date.parse(a.connection.start) || 0);
      return traffic || start || (a.key < b.key ? -1 : (a.key > b.key ? 1 : 0));
    });
    this.samples = samples;
    this.positions.clear();
    this.ranked.clear();
    ranked.forEach((row: ConnectionRecordView, index: number): void => {
      this.positions.set(row.key, index);
      this.ranked.set(row.key, row);
    });
    return ranked;
  }
}

function recordColumn(id: string, width: number, flex: number = 0, numeric: boolean = false): RecordColumn {
  return { id: id, width: width, flex: flex, numeric: numeric, resizable: true, descending: numeric };
}

export function recordColumns(view: RecordView, width: number,
  headerWidths: Record<string, number>): RecordColumn[] {
  if (width < 720) {
    return [];
  }
  const wide = width >= 1000;
  const protocolWidth = Math.max(56, headerWidths['protocol'] ?? 0);
  if (view === 'dns') {
    const columns: RecordColumn[] = [recordColumn('time', 80, 0, true), recordColumn('domain', 0, 1.3),
      recordColumn('type', 72), recordColumn('initiator', 72), recordColumn('result', 0, 1),
      recordColumn('elapsed', 76, 0, true)];
    if (wide) {
      columns.push(recordColumn('upstream', 0, 0.8));
    }
    return columns;
  }
  const columns: RecordColumn[] = [];
  if (view === 'requests') {
    columns.push(recordColumn('time', 80, 0, true));
  }
  columns.push(recordColumn('target', 0, wide ? 1.4 : 1.3));
  if ((view === 'requests' && wide) || (view === 'connections' && width >= 1200)) {
    columns.push(recordColumn('protocol', protocolWidth));
  }
  if (view === 'requests' || wide) {
    columns.push(recordColumn('rule', 0, 1));
  }
  columns.push(recordColumn('exit', 120));
  if (view === 'connections') {
    columns.push(recordColumn('downloadSpeed', 100, 0, true), recordColumn('uploadSpeed', 100, 0, true));
  }
  if (wide) {
    const downloadWidth = view === 'requests' ? 100 : Math.max(88, headerWidths['download'] ?? 0);
    const uploadWidth = view === 'requests' ? 100 : Math.max(88, headerWidths['upload'] ?? 0);
    columns.push(recordColumn('download', downloadWidth, 0, true),
      recordColumn('upload', uploadWidth, 0, true));
  } else {
    columns.push(recordColumn('traffic', 88, 0, true));
  }
  if (view === 'connections' && width >= 1200) {
    columns.push(recordColumn('duration', 80, 0, true));
  }
  return columns;
}

export function tableColumnWidths(columns: RecordColumn[], width: number,
  overrides: Record<string, number> = {}): number[] {
  const sized: number[] = [];
  let fixed = 0;
  let flex = 0;
  let flexCount = 0;
  for (const column of columns) {
    const size = overrides[column.id] ?? column.width;
    sized.push(size);
    if (size === 0) {
      flex += column.flex;
      flexCount++;
    } else {
      fixed += size;
    }
  }
  const free = width - fixed;
  if (Object.keys(overrides).length === 0 || (flexCount > 0 && free >= flexCount * 48)) {
    const share = Math.max(0, free);
    return columns.map<number>((column: RecordColumn, index: number): number =>
      sized[index] === 0 ? (flex === 0 ? 0 : share * column.flex / flex) : sized[index]);
  }
  // 与 Prism 一致：拖宽后没有剩余弹性列，或窗口变窄时，按自然宽度比例适配。
  const natural = sized.map<number>((size: number): number => size === 0 ? 48 : size);
  const total = natural.reduce<number>((sum: number, size: number): number => sum + size, 0);
  return natural.map<number>((size: number): number => total === 0 ? 0 : size * width / total);
}

export function resizedTableColumns(columns: RecordColumn[], widths: number[],
  overrides: Record<string, number>, boundary: number, delta: number): Record<string, number> {
  const result: Record<string, number> = {};
  for (const key of Object.keys(overrides)) {
    result[key] = overrides[key];
  }
  if (boundary < 0 || boundary >= columns.length - 1 || widths.length !== columns.length ||
    !columns[boundary].resizable || !columns[boundary + 1].resizable) {
    return result;
  }
  const resized = widths.slice();
  if (delta > 0) {
    let rest = delta;
    for (let index = boundary + 1; index < columns.length && rest > 0; index++) {
      if (!columns[index].resizable) {
        continue;
      }
      const taken = Math.min(rest, Math.max(0, resized[index] - 48));
      resized[index] -= taken;
      rest -= taken;
    }
    resized[boundary] += delta - rest;
  } else {
    const given = Math.min(-delta, Math.max(0, resized[boundary] - 48));
    resized[boundary] -= given;
    resized[boundary + 1] += given;
  }
  columns.forEach((column: RecordColumn, index: number): void => {
    if (resized[index] !== widths[index]) {
      result[column.id] = resized[index];
    }
  });
  return result;
}
