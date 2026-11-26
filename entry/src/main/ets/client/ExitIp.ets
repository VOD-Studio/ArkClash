import { RoutedProbeRequest } from './RoutedProbe';
import { RoutedProbeError, RoutedProbeFailure } from './ProbeProtocol';
import { EXIT_IP_QUALITY_SOURCES, ExitIpQuality, exitIpQualityUrl, parseExitIpQuality } from './ExitIpQuality';

const LOOKUP_URLS: string[] = ['https://ipwho.is/', 'https://api.ip.sb/geoip'];
const TIMEOUT_MS = 5000;
const REFRESH_MS = 60000;
const QUALITY_MAX_AGE_MS = 3 * 24 * 60 * 60 * 1000;
const QUALITY_TIMEOUT_MS = 8000;
const QUALITY_CACHE_LIMIT = 32;

interface ExitIpConnection {
  org?: string;
  isp?: string;
  asn?: number;
}

interface ExitLookupResponse {
  success?: boolean;
  ip?: string;
  country?: string;
  country_code?: string;
  connection?: ExitIpConnection;
  organization?: string;
  asn_organization?: string;
  asn?: number;
}

export interface ExitIp {
  ip: string;
  country: string;
  countryCode: string;
  org: string;
  asn: string;
  source: string;
  checkedAt: number;
  route: string;
  routed: boolean;
  bootId: string;
  revision: number;
}

export function validExitAddress(address: string): boolean {
  if (new RegExp('^[0-9]{1,3}(\\.[0-9]{1,3}){3}$').test(address)) {
    return address.split('.').every((part: string): boolean => Number(part) <= 255);
  }
  if (!address.includes(':') || address.length > 39 || !new RegExp('^[0-9a-fA-F:]+$').test(address)) {
    return false;
  }
  const halves = address.split('::');
  if (halves.length > 2 || halves.some((half: string): boolean => half.startsWith(':') || half.endsWith(':'))) {
    return false;
  }
  const groups = address.split(':').filter((part: string): boolean => part !== '');
  if (!groups.every((part: string): boolean => part.length <= 4)) {
    return false;
  }
  return halves.length === 2 ? groups.length < 8 : groups.length === 8 &&
    !address.startsWith(':') && !address.endsWith(':');
}

@ObservedV2
export class ExitIpProbe {
  @Trace result: ExitIp | undefined = undefined;
  @Trace busy: boolean = false;
  @Trace failed: boolean = false;
  @Trace stale: boolean = false;
  @Trace failure: RoutedProbeFailure | '' = '';
  @Trace quality: ExitIpQuality | undefined = undefined;
  @Trace qualityBusy: boolean = false;
  @Trace qualityFailed: boolean = false;
  private generation: number = 0;
  private filesDir: string = '';
  private route: string = '';
  private routed: boolean = false;
  private observing: boolean = false;
  private lastStartedAt: number = 0;
  private request?: RoutedProbeRequest;
  private qualityCache: Map<string, ExitIpQuality> = new Map();

  observe(filesDir: string, route: string, routed: boolean, active: boolean): void {
    const changed = route !== this.route || routed !== this.routed;
    this.filesDir = filesDir;
    if (changed) {
      this.cancel();
      this.route = route;
      this.routed = routed;
      this.result = undefined;
      this.quality = undefined;
      this.qualityFailed = false;
      this.failed = false;
      this.failure = '';
      this.stale = false;
      this.lastStartedAt = 0;
    }
    this.observing = active;
    if (!active) {
      this.cancel();
      this.stale = this.result !== undefined;
      return;
    }
    if (!this.busy && (this.lastStartedAt === 0 || Date.now() - this.lastStartedAt >= REFRESH_MS)) {
      this.refresh(false);
    }
  }

  cancel(): void {
    this.generation++;
    this.request?.cancel();
    this.request = undefined;
    this.busy = false;
    this.qualityBusy = false;
  }

  async refresh(forceQuality: boolean = true): Promise<void> {
    if (!this.observing || this.busy) {
      return;
    }
    const generation = ++this.generation;
    const route = this.route;
    const routed = this.routed;
    this.busy = true;
    this.failed = false;
    this.failure = '';
    this.stale = this.result !== undefined;
    this.lastStartedAt = Date.now();
    try {
      for (const source of LOOKUP_URLS) {
        if (generation !== this.generation) {
          return;
        }
        const request = new RoutedProbeRequest();
        this.request = request;
        try {
          const response = await request.run(this.filesDir, { url: source, method: 'GET', bodyMode: 'json' },
            TIMEOUT_MS, routed);
          if (generation !== this.generation) {
            return;
          }
          if (response.status !== 200) {
            continue;
          }
          const body = JSON.parse(response.body) as ExitLookupResponse;
          const address = body.ip ?? '';
          if (body.success === false || !validExitAddress(address)) {
            continue;
          }
          this.result = {
            ip: address,
            country: body.country ?? '',
            countryCode: body.country_code ?? '',
            org: body.connection?.org ?? body.connection?.isp ?? body.asn_organization ?? body.organization ?? '',
            asn: body.connection?.asn !== undefined ? `AS${body.connection.asn}` :
              (body.asn !== undefined ? `AS${body.asn}` : ''),
            source: source,
            checkedAt: Date.now(),
            route: route,
            routed: routed,
            bootId: response.bootId,
            revision: response.revision
          };
          this.stale = false;
          await this.refreshQuality(generation, this.result, forceQuality);
          return;
        } catch (e) {
          if (generation !== this.generation) {
            return;
          }
          if (e instanceof RoutedProbeError && (e.reason === 'routeChanged' || e.reason === 'capacity' ||
            e.reason === 'controller' || e.reason === 'cancelled')) {
            throw e;
          }
        } finally {
          if (this.request === request) {
            this.request = undefined;
          }
        }
      }
      throw new RoutedProbeError('invalidResponse');
    } catch (e) {
      if (generation === this.generation) {
        this.failed = true;
        this.failure = e instanceof RoutedProbeError ? e.reason : 'transport';
        if (this.failure === 'routeChanged') {
          this.result = undefined;
          this.quality = undefined;
          this.stale = false;
        }
      }
    } finally {
      if (generation === this.generation) {
        this.busy = false;
      }
    }
  }

  private async refreshQuality(generation: number, result: ExitIp, force: boolean): Promise<void> {
    const cached = this.qualityCache.get(result.ip);
    if (force || this.quality?.ip !== result.ip) {
      this.quality = undefined;
    }
    this.qualityFailed = false;
    if (!force && cached !== undefined && Date.now() - cached.checkedAt < QUALITY_MAX_AGE_MS) {
      this.quality = cached;
      return;
    }
    this.qualityBusy = true;
    const deadline = Date.now() + QUALITY_TIMEOUT_MS;
    try {
      for (const source of EXIT_IP_QUALITY_SOURCES) {
        if (generation !== this.generation || this.result !== result) {
          return;
        }
        if (Date.now() >= deadline) {
          break;
        }
        const request = new RoutedProbeRequest();
        this.request = request;
        try {
          const response = await request.run(this.filesDir,
            { url: exitIpQualityUrl(source, result.ip), method: 'GET', bodyMode: 'json' },
            Math.min(TIMEOUT_MS, deadline - Date.now()), result.routed);
          if (generation !== this.generation || this.result !== result) {
            return;
          }
          if (response.bootId !== result.bootId || response.revision !== result.revision) {
            throw new RoutedProbeError('routeChanged');
          }
          if (response.status !== 200) {
            continue;
          }
          const quality = parseExitIpQuality(response.body, result.ip, source);
          if (quality === undefined) {
            continue;
          }
          this.quality = quality;
          if (this.qualityCache.size >= QUALITY_CACHE_LIMIT && !this.qualityCache.has(result.ip)) {
            for (const oldest of this.qualityCache.keys()) {
              this.qualityCache.delete(oldest);
              break;
            }
          }
          this.qualityCache.set(result.ip, quality);
          return;
        } catch (e) {
          if (generation !== this.generation) {
            return;
          }
          if (e instanceof RoutedProbeError && e.reason === 'routeChanged') {
            throw e;
          }
        } finally {
          if (this.request === request) {
            this.request = undefined;
          }
        }
      }
      this.qualityFailed = true;
    } finally {
      if (generation === this.generation) {
        this.qualityBusy = false;
      }
    }
  }
}

export function flagOf(countryCode: string): string {
  if (!new RegExp('^[A-Za-z]{2}$').test(countryCode)) {
    return '';
  }
  const upper = countryCode.toUpperCase();
  return String.fromCodePoint(0x1F1E6 + upper.charCodeAt(0) - 65, 0x1F1E6 + upper.charCodeAt(1) - 65);
}

export const exitIpProbe: ExitIpProbe = new ExitIpProbe();
