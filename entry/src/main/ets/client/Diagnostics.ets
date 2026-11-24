import { http } from '@kit.NetworkKit';
import { call } from './Controller';
import { ControllerSocket, ControllerSocketState } from './ControllerSocket';

export type DiagnosticFeedTarget = 'live' | 'recent' | 'dns';

export interface DiagnosticRuntime {
  bootId: string;
  configRevision: number;
}

export interface DiagnosticStatsFrame extends DiagnosticRuntime {
  type: 'stats';
  live: number;
  recent: number;
  dns: number;
}

export interface DiagnosticMetadata {
  network: string;
  type: string;
  sourceIP: string;
  sourcePort: string;
  destinationIP: string;
  destinationPort: string;
  host: string;
  dnsMode: string;
  remoteDestination: string;
  sourceIPASN: string;
  destinationIPASN: string;
  specialProxy: string;
  specialRules: string;
  sniffHost: string;
  sourceGeoIP: string[];
  destinationGeoIP: string[];
}

export interface DiagnosticConnection {
  id: string;
  start: string;
  metadata: DiagnosticMetadata;
  chains: string[];
  providerChains: string[];
  rule: string;
  rulePayload: string;
  upload: number;
  download: number;
}

export interface DiagnosticTraffic {
  id: string;
  upload: number;
  download: number;
}

export interface DiagnosticDnsRecord {
  id: string;
  domain: string;
  type: string;
  initiator: string;
  upstream: string;
  rcode: string;
  error: string;
  cached: boolean;
  answers: string[];
  delay: number;
  time: string;
}

interface DiagnosticFrameHeader extends DiagnosticRuntime {
  type: string;
  kind: 'snapshot' | 'delta' | 'reset';
  sessionId: string;
  seq: number;
  sampledAt: number;
  dropped: number;
  evicted: number;
}

export interface DiagnosticConnectionsFrame extends DiagnosticFrameHeader {
  type: 'connections';
  live: DiagnosticConnection[];
  recent: DiagnosticConnection[];
  opened: DiagnosticConnection[];
  traffic: DiagnosticTraffic[];
  closed: string[];
}

export interface DiagnosticDnsFrame extends DiagnosticFrameHeader {
  type: 'dns';
  records: DiagnosticDnsRecord[];
  added: DiagnosticDnsRecord[];
}

interface DiagnosticActionBody {
  expectedBootId: string;
  expectedConfigRevision: number;
  scope?: 'one' | 'all';
  id?: string;
}

const DIAGNOSTIC_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;

export function diagnosticError(error: Object): string {
  const message = (error as Error).message;
  const codes: string[] = ['diagnostics_invalid_request', 'diagnostics_stale_runtime', 'diagnostics_not_ready',
    'diagnostics_operation_failed', 'diagnostics_invalid_data', 'diagnostics_stream_failed',
    'diagnostics_preferences_failed'];
  return codes.includes(message) ? message : 'diagnostics_operation_failed';
}

function diagnosticCount(count: number): boolean { return Number.isSafeInteger(count) && count >= 0; }
function diagnosticObject(item: Object): boolean { return item !== null && typeof item === 'object'; }
function diagnosticStrings(items: string[]): boolean {
  return Array.isArray(items) && items.every((item: string): boolean => typeof item === 'string');
}
function diagnosticTime(text: string): boolean {
  return typeof text === 'string' && DIAGNOSTIC_TIME.test(text) && Number.isFinite(Date.parse(text));
}
function validDiagnosticRuntime(runtime: DiagnosticRuntime): boolean {
  return diagnosticObject(runtime) && typeof runtime.bootId === 'string' && runtime.bootId.trim() !== '' &&
    Number.isSafeInteger(runtime.configRevision) && runtime.configRevision > 0;
}
function diagnosticJson(text: string): Object {
  try {
    const parsed = JSON.parse(text) as Object;
    if (diagnosticObject(parsed)) { return parsed; }
  } catch (_error) {}
  throw new Error('diagnostics_invalid_data');
}
function diagnosticHeader(frame: DiagnosticFrameHeader, runtime: DiagnosticRuntime, type: string): boolean {
  return frame.type === type && ['snapshot', 'delta', 'reset'].includes(frame.kind) &&
    frame.bootId === runtime.bootId && frame.configRevision === runtime.configRevision &&
    validDiagnosticRuntime(frame) && typeof frame.sessionId === 'string' && frame.sessionId !== '' &&
    Number.isSafeInteger(frame.seq) && frame.seq > 0 && diagnosticCount(frame.sampledAt) &&
    diagnosticCount(frame.dropped) && diagnosticCount(frame.evicted);
}
function diagnosticPort(port: string): boolean {
  return typeof port === 'string' && /^\d+$/.test(port) && Number(port) <= 65535;
}
function diagnosticMetadata(metadata: DiagnosticMetadata): boolean {
  return diagnosticObject(metadata) && typeof metadata.network === 'string' && typeof metadata.type === 'string' &&
    typeof metadata.sourceIP === 'string' && diagnosticPort(metadata.sourcePort) &&
    typeof metadata.destinationIP === 'string' && diagnosticPort(metadata.destinationPort) &&
    typeof metadata.host === 'string' && typeof metadata.dnsMode === 'string' &&
    typeof metadata.remoteDestination === 'string' && typeof metadata.sourceIPASN === 'string' &&
    typeof metadata.destinationIPASN === 'string' && typeof metadata.specialProxy === 'string' &&
    typeof metadata.specialRules === 'string' && typeof metadata.sniffHost === 'string' &&
    diagnosticStrings(metadata.sourceGeoIP) && diagnosticStrings(metadata.destinationGeoIP);
}
function diagnosticConnection(record: DiagnosticConnection): boolean {
  return diagnosticObject(record) && typeof record.id === 'string' && record.id !== '' &&
    diagnosticTime(record.start) && diagnosticMetadata(record.metadata) && diagnosticStrings(record.chains) &&
    diagnosticStrings(record.providerChains) && typeof record.rule === 'string' && typeof record.rulePayload === 'string' &&
    diagnosticCount(record.upload) && diagnosticCount(record.download);
}
function diagnosticTraffic(record: DiagnosticTraffic): boolean {
  return diagnosticObject(record) && typeof record.id === 'string' && record.id !== '' &&
    diagnosticCount(record.upload) && diagnosticCount(record.download);
}
function diagnosticDns(record: DiagnosticDnsRecord): boolean {
  return diagnosticObject(record) && typeof record.id === 'string' && record.id !== '' &&
    typeof record.domain === 'string' && typeof record.type === 'string' &&
    ['app', 'rule', 'direct', 'proxy', 'other'].includes(record.initiator) && typeof record.upstream === 'string' &&
    typeof record.rcode === 'string' && typeof record.error === 'string' && typeof record.cached === 'boolean' &&
    diagnosticStrings(record.answers) && diagnosticCount(record.delay) && diagnosticTime(record.time);
}

export function parseDiagnosticConnections(text: string, runtime: DiagnosticRuntime): DiagnosticConnectionsFrame {
  const frame = diagnosticJson(text) as DiagnosticConnectionsFrame;
  if (!diagnosticHeader(frame, runtime, 'connections') ||
    (frame.kind === 'delta' ? !Array.isArray(frame.opened) || !Array.isArray(frame.traffic) || !Array.isArray(frame.closed) :
      !Array.isArray(frame.live) || !Array.isArray(frame.recent))) {
    throw new Error('diagnostics_invalid_data');
  }
  if (frame.live === undefined) { frame.live = []; }
  if (frame.recent === undefined) { frame.recent = []; }
  if (frame.opened === undefined) { frame.opened = []; }
  if (frame.traffic === undefined) { frame.traffic = []; }
  if (frame.closed === undefined) { frame.closed = []; }
  if (!Array.isArray(frame.live) || !frame.live.every((record: DiagnosticConnection): boolean => diagnosticConnection(record)) ||
    !Array.isArray(frame.recent) || !frame.recent.every((record: DiagnosticConnection): boolean => diagnosticConnection(record)) ||
    !Array.isArray(frame.opened) || !frame.opened.every((record: DiagnosticConnection): boolean => diagnosticConnection(record)) ||
    !Array.isArray(frame.traffic) || !frame.traffic.every((record: DiagnosticTraffic): boolean => diagnosticTraffic(record)) ||
    !diagnosticStrings(frame.closed) || frame.closed.some((id: string): boolean => id === '')) {
    throw new Error('diagnostics_invalid_data');
  }
  return frame;
}

export function parseDiagnosticDns(text: string, runtime: DiagnosticRuntime): DiagnosticDnsFrame {
  const frame = diagnosticJson(text) as DiagnosticDnsFrame;
  if (!diagnosticHeader(frame, runtime, 'dns') ||
    (frame.kind === 'delta' ? !Array.isArray(frame.added) : !Array.isArray(frame.records))) {
    throw new Error('diagnostics_invalid_data');
  }
  if (frame.records === undefined) { frame.records = []; }
  if (frame.added === undefined) { frame.added = []; }
  if (!Array.isArray(frame.records) || !frame.records.every((record: DiagnosticDnsRecord): boolean => diagnosticDns(record)) ||
    !Array.isArray(frame.added) || !frame.added.every((record: DiagnosticDnsRecord): boolean => diagnosticDns(record))) {
    throw new Error('diagnostics_invalid_data');
  }
  return frame;
}

export function parseDiagnosticStats(text: string, runtime: DiagnosticRuntime): DiagnosticStatsFrame {
  const frame = diagnosticJson(text) as DiagnosticStatsFrame;
  if (frame.type !== 'stats' || !validDiagnosticRuntime(frame) ||
    frame.bootId !== runtime.bootId || frame.configRevision !== runtime.configRevision ||
    !diagnosticCount(frame.live) || !diagnosticCount(frame.recent) || !diagnosticCount(frame.dns)) {
    throw new Error('diagnostics_invalid_data');
  }
  return frame;
}

function diagnosticStreamPath(feed: string, runtime: DiagnosticRuntime): string {
  return `/arkclash/diagnostics/${feed}?expectedBootId=${encodeURIComponent(runtime.bootId)}` +
    `&expectedConfigRevision=${runtime.configRevision}`;
}

export function createDiagnosticStatsStream(runtime: DiagnosticRuntime,
  onFrame: (frame: DiagnosticStatsFrame) => void,
  onState: (state: ControllerSocketState) => void): ControllerSocket {
  const identity: DiagnosticRuntime = { bootId: runtime.bootId, configRevision: runtime.configRevision };
  const stream = new ControllerSocket(diagnosticStreamPath('stats', identity), (text: string): void => {
    let frame: DiagnosticStatsFrame;
    try { frame = parseDiagnosticStats(text, identity); }
    catch (_error) { stream.fail('diagnostics_invalid_data'); return; }
    onFrame(frame);
  }, onState);
  return stream;
}

@ObservedV2
export class DiagnosticStats {
  @Trace live: number = 0;
  @Trace recent: number = 0;
  @Trace dns: number = 0;
  @Trace synced: boolean = false;
  @Trace streamState: ControllerSocketState = 'closed';
  private visible: boolean = false;
  private ready: boolean = false;
  private filesDir: string = '';
  private runtime: DiagnosticRuntime = { bootId: '', configRevision: 0 };
  private socket?: ControllerSocket;
  private generation: number = 0;

  observe(filesDir: string, visible: boolean, ready: boolean, bootId: string, configRevision: number): void {
    this.filesDir = filesDir;
    const valid = bootId !== '' && Number.isSafeInteger(configRevision) && configRevision > 0;
    const nextBoot = valid ? bootId : '';
    const nextRevision = valid ? configRevision : 0;
    const runtimeChanged = nextBoot !== this.runtime.bootId || nextRevision !== this.runtime.configRevision;
    if (runtimeChanged) {
      this.runtime = { bootId: nextBoot, configRevision: nextRevision };
      this.resetCounts();
    }
    this.visible = visible;
    this.ready = ready && valid;
    if (runtimeChanged || !this.visible || !this.ready || this.filesDir === '') {
      this.stopStream();
    }
    if (this.visible && this.ready && this.filesDir !== '' && this.socket === undefined) {
      this.startStream();
    }
  }

  stop(): void {
    this.visible = false;
    this.stopStream();
  }

  private startStream(): void {
    const generation = ++this.generation;
    const identity: DiagnosticRuntime = { bootId: this.runtime.bootId, configRevision: this.runtime.configRevision };
    const socket = createDiagnosticStatsStream(identity,
      (frame: DiagnosticStatsFrame): void => {
        if (generation !== this.generation || !this.visible || !this.ready) { return; }
        this.live = frame.live;
        this.recent = frame.recent;
        this.dns = frame.dns;
        this.synced = true;
      },
      (state: ControllerSocketState): void => {
        if (generation !== this.generation) { return; }
        this.streamState = state;
        if (state !== 'open') { this.synced = false; }
      });
    this.socket = socket;
    socket.start(this.filesDir);
  }

  private stopStream(): void {
    ++this.generation;
    const socket = this.socket;
    this.socket = undefined;
    socket?.stop();
    this.synced = false;
    this.streamState = 'closed';
  }

  private resetCounts(): void {
    this.live = 0;
    this.recent = 0;
    this.dns = 0;
    this.synced = false;
  }
}

export function createConnectionsStream(runtime: DiagnosticRuntime,
  onFrame: (frame: DiagnosticConnectionsFrame) => void,
  onState: (state: ControllerSocketState) => void): ControllerSocket {
  const identity: DiagnosticRuntime = { bootId: runtime.bootId, configRevision: runtime.configRevision };
  const stream = new ControllerSocket(diagnosticStreamPath('connections', identity), (text: string): void => {
    let frame: DiagnosticConnectionsFrame;
    try { frame = parseDiagnosticConnections(text, identity); }
    catch (_error) { stream.fail('diagnostics_invalid_data'); return; }
    onFrame(frame);
  }, onState);
  return stream;
}

export function createDnsStream(runtime: DiagnosticRuntime, onFrame: (frame: DiagnosticDnsFrame) => void,
  onState: (state: ControllerSocketState) => void): ControllerSocket {
  const identity: DiagnosticRuntime = { bootId: runtime.bootId, configRevision: runtime.configRevision };
  const stream = new ControllerSocket(diagnosticStreamPath('dns', identity), (text: string): void => {
    let frame: DiagnosticDnsFrame;
    try { frame = parseDiagnosticDns(text, identity); }
    catch (_error) { stream.fail('diagnostics_invalid_data'); return; }
    onFrame(frame);
  }, onState);
  return stream;
}

export async function closeDiagnosticConnections(filesDir: string, runtime: DiagnosticRuntime,
  scope: 'one' | 'all', id?: string): Promise<void> {
  if (!validDiagnosticRuntime(runtime) || (scope !== 'one' && scope !== 'all') ||
    (scope === 'one' ? typeof id !== 'string' || id.trim() === '' : id !== undefined)) {
    throw new Error('diagnostics_invalid_request');
  }
  const body: DiagnosticActionBody = { expectedBootId: runtime.bootId,
    expectedConfigRevision: runtime.configRevision, scope: scope, id: id };
  try { await call(filesDir, http.RequestMethod.POST, '/arkclash/diagnostics/connections/close', JSON.stringify(body)); }
  catch (error) { throw new Error(diagnosticError(error as Object)); }
}

export async function clearDiagnosticDnsCache(filesDir: string, runtime: DiagnosticRuntime): Promise<void> {
  if (!validDiagnosticRuntime(runtime)) { throw new Error('diagnostics_invalid_request'); }
  const body: DiagnosticActionBody = { expectedBootId: runtime.bootId, expectedConfigRevision: runtime.configRevision };
  try { await call(filesDir, http.RequestMethod.POST, '/arkclash/diagnostics/dns/clear-cache', JSON.stringify(body)); }
  catch (error) { throw new Error(diagnosticError(error as Object)); }
}
