import { generalUserAgent } from '../GeneralSettings';
import { util, url as urlKit } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { errorString, ProfileError } from './Errors';
import { SubscriptionUsage } from './Store';

export const USER_AGENT = 'ArkClash clash.meta';
export const DOWNLOAD_TIMEOUT_MS = 20000;
export const CONNECT_TIMEOUT_MS = DOWNLOAD_TIMEOUT_MS;
export const READ_TIMEOUT_MS = DOWNLOAD_TIMEOUT_MS;

export interface DownloadInfo {
  name?: string;
  usage?: SubscriptionUsage;
}

export interface DownloadRequestIdentity {
  canceled: () => boolean;
  maxBytes?: number;
}

export interface Downloader {
  download(url: string, path: string, identity?: DownloadRequestIdentity): Promise<DownloadInfo>;
}

export function nameFromDisposition(header: string | undefined): string | undefined {
  if (header === undefined) {
    return undefined;
  }
  const encoded = new RegExp("filename\\*\\s*=\\s*[^']*''([^;]+)", 'i').exec(header);
  let name: string | undefined = undefined;
  if (encoded !== null) {
    try {
      name = decodeURIComponent(encoded[1].trim());
    } catch (e) {
      name = undefined;
    }
  }
  if (name === undefined) {
    const plain = new RegExp('filename\\s*=\\s*(?:"([^"\\r\\n]+)"|([^;\\r\\n]+))', 'i').exec(header);
    name = plain !== null ? (plain[1] ?? plain[2]).trim() : undefined;
  }
  const trimmed = name?.trim();
  return trimmed !== undefined && trimmed.length > 0 ? trimmed : undefined;
}

export function parseUsage(header: string | undefined): SubscriptionUsage {
  const usage: SubscriptionUsage = { upload: 0, download: 0, total: 0, expire: 0 };
  for (const part of (header ?? '').split(';')) {
    const separator = part.indexOf('=');
    if (separator < 0) {
      continue;
    }
    const raw = part.substring(separator + 1).trim();
    if (raw === '') {
      continue;
    }
    const parsed = Number(raw);
    if (!Number.isFinite(parsed)) {
      continue;
    }
    const amount = Math.max(0, Math.trunc(parsed));
    switch (part.substring(0, separator).trim().toLowerCase()) {
      case 'upload':
        usage.upload = amount;
        break;
      case 'download':
        usage.download = amount;
        break;
      case 'total':
        usage.total = amount;
        break;
      case 'expire':
        usage.expire = amount;
        break;
      default:
        break;
    }
  }
  return usage;
}

export function infoFromHeaders(header: Record<string, string>): DownloadInfo {
  const normalized: Record<string, string> = {};
  for (const key of Object.keys(header)) {
    normalized[key.toLowerCase()] = header[key];
  }
  return {
    name: nameFromDisposition(normalized['content-disposition']),
    usage: parseUsage(normalized['subscription-userinfo'])
  };
}

export function validSubscriptionUrl(raw: string): boolean {
  if (raw.length === 0 || raw.length > 2048 || new RegExp('\\s').test(raw)) {
    return false;
  }
  try {
    const parsed = new urlKit.URL(raw);
    return ['http:', 'https:', 'ftp:'].includes(parsed.protocol.toLowerCase()) && parsed.hostname.length > 0;
  } catch (e) {
    return false;
  }
}

export function hostOf(raw: string): string {
  try {
    return new urlKit.URL(raw).hostname;
  } catch (e) {
    return '';
  }
}

export interface ProfileDownloadAddress {
  address: string;
  headers: Record<string, string>;
}

export async function prepareDownloadAddress(raw: string, userAgent: string = USER_AGENT):
  Promise<ProfileDownloadAddress> {
  if (!validSubscriptionUrl(raw)) {
    throw new ProfileError('url_invalid');
  }
  const headers: Record<string, string> = { 'User-Agent': userAgent };
  const authority = new RegExp('^([a-z]+://)([^/?#]*)', 'i').exec(raw);
  const separator = authority?.[2].lastIndexOf('@') ?? -1;
  if (authority !== null && separator >= 0) {
    const userinfo = authority[2].substring(0, separator);
    let credentials: string;
    try {
      credentials = decodeURIComponent(userinfo);
    } catch (e) {
      throw new ProfileError('url_invalid');
    }
    const encoded = await new util.Base64Helper().encodeToString(new util.TextEncoder().encodeInto(credentials));
    headers['Authorization'] = `Basic ${encoded}`;
    return { address: `${authority[1]}${authority[2].substring(separator + 1)}${raw.substring(authority[0].length)}`,
      headers: headers };
  }
  return { address: raw, headers: headers };
}

function lowerCaseHeaders(headers: Object): Record<string, string> {
  const record = headers as Record<string, string | string[]>;
  const result: Record<string, string> = {};
  for (const key of Object.keys(record)) {
    const header = record[key];
    result[key.toLowerCase()] = typeof header === 'string' ? header : header[0];
  }
  return result;
}

async function writeBuffer(path: string, data: ArrayBuffer): Promise<void> {
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    if (await fs.write(file.fd, data) !== data.byteLength) {
      throw new ProfileError('io');
    }
    await fs.fsync(file.fd);
  } finally {
    await fs.close(file);
  }
}

export class DirectDownloader implements Downloader {
  private filesDir: string;

  constructor(filesDir: string = '') { this.filesDir = filesDir; }
  async download(raw: string, path: string, identity?: DownloadRequestIdentity): Promise<DownloadInfo> {
    const address = await prepareDownloadAddress(raw, await generalUserAgent(this.filesDir));
    const request = http.createHttp();
    let expired = false;
    let rejectTimeout: ((error: Error) => void) | undefined = undefined;
    const deadline = new Promise<http.HttpResponse>((_resolve: (response: http.HttpResponse) => void,
      reject: (error: Error) => void): void => { rejectTimeout = reject; });
    const timer = setTimeout((): void => {
      expired = true;
      request.destroy();
      rejectTimeout?.(new ProfileError('timeout') as Error);
    }, DOWNLOAD_TIMEOUT_MS);
    try {
      if (identity?.canceled() === true) {
        throw new ProfileError('canceled');
      }
      let response: http.HttpResponse;
      try {
        const pending: Promise<http.HttpResponse> = request.request(address.address, {
          method: http.RequestMethod.GET,
          header: address.headers,
          connectTimeout: DOWNLOAD_TIMEOUT_MS,
          readTimeout: DOWNLOAD_TIMEOUT_MS,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          maxLimit: identity?.maxBytes
        });
        response = await Promise.race<http.HttpResponse>([pending, deadline]);
        clearTimeout(timer);
      } catch (e) {
        throw new ProfileError(expired ? 'timeout' : errorString(e as Object));
      }
      if (expired) {
        throw new ProfileError('timeout');
      }
      if (identity?.canceled() === true) {
        throw new ProfileError('canceled');
      }
      if (response.responseCode !== 200) {
        throw new ProfileError('http', `${response.responseCode}`);
      }
      try { await writeBuffer(path, response.result as ArrayBuffer); }
      catch (e) { throw new ProfileError('io'); }
      return infoFromHeaders(lowerCaseHeaders(response.header));
    } finally {
      clearTimeout(timer);
      if (!expired) { request.destroy(); }
    }
  }
}
