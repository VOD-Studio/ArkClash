import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { ProfileError } from './Errors';
import { SubscriptionUsage } from './Store';

// 机场只给认得的客户端返回 Clash YAML。
export const USER_AGENT = 'clash.meta';
export const CONNECT_TIMEOUT_MS = 15000;
export const READ_TIMEOUT_MS = 30000;

/** 响应头里的订阅信息。 */
export interface DownloadInfo {
  name?: string; // Content-Disposition 给的文件名，没有时为 undefined
  usage?: SubscriptionUsage;
}

/** 把订阅下载到 path；失败时抛出 ProfileError。界面进程直连，VPN 进程先经内核（vpn/KernelDownloader.ets）。 */
export interface Downloader {
  download(url: string, path: string): Promise<DownloadInfo>;
}

// 机场常在 Content-Disposition 里给订阅名：filename*=UTF-8''<百分号编码> 或 filename="..."。
function nameFromDisposition(value: string | undefined): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  const encoded = /filename\*\s*=\s*[^']*''([^;]+)/i.exec(value);
  let name: string | undefined;
  if (encoded !== null) {
    try {
      name = decodeURIComponent(encoded[1].trim());
    } catch (e) {
      name = undefined;
    }
  }
  if (name === undefined) {
    const plain = /filename\s*=\s*"?([^";]+)"?/i.exec(value);
    name = plain !== null ? plain[1].trim() : undefined;
  }
  const trimmed = name?.replace(/\.(ya?ml|txt)$/i, '').trim();
  return trimmed !== undefined && trimmed.length > 0 ? trimmed : undefined;
}

function parseUsage(value: string | undefined): SubscriptionUsage | undefined {
  if (value === undefined) {
    return undefined;
  }
  const usage: SubscriptionUsage = { upload: 0, download: 0, total: 0, expire: 0 };
  for (const part of value.split(';')) {
    const pair = part.split('=');
    if (pair.length !== 2) {
      continue;
    }
    const n = Number(pair[1].trim());
    if (!Number.isFinite(n)) {
      continue;
    }
    switch (pair[0].trim()) {
      case 'upload':
        usage.upload = n;
        break;
      case 'download':
        usage.download = n;
        break;
      case 'total':
        usage.total = n;
        break;
      case 'expire':
        usage.expire = n;
        break;
      default:
        break;
    }
  }
  return usage.total > 0 ? usage : undefined;
}

/** header 的键必须是小写。 */
export function infoFromHeaders(header: Record<string, string>): DownloadInfo {
  return {
    name: nameFromDisposition(header['content-disposition']),
    usage: parseUsage(header['subscription-userinfo'])
  };
}

export function hostOf(url: string): string {
  const match = /^[a-z]+:\/\/(?:[^@/?#]*@)?([^/:?#]+)/i.exec(url);
  return match !== null ? match[1] : url;
}

function lowerCaseHeaders(headers: Object): Record<string, string> {
  const record = headers as Record<string, string | string[]>;
  const result: Record<string, string> = {};
  for (const key of Object.keys(record)) {
    const value = record[key];
    result[key.toLowerCase()] = typeof value === 'string' ? value : value[0];
  }
  return result;
}

async function writeBuffer(path: string, data: ArrayBuffer): Promise<void> {
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    await fs.write(file.fd, data);
  } finally {
    await fs.close(file);
  }
}

/** 直连下载。界面进程不走 VPN；VPN 进程开了 protectProcessNet，这里发出的请求也是直连。 */
export class DirectDownloader implements Downloader {
  async download(url: string, path: string): Promise<DownloadInfo> {
    const request = http.createHttp();
    try {
      const header: Record<string, string> = { 'User-Agent': USER_AGENT };
      let response: http.HttpResponse;
      try {
        response = await request.request(url, {
          method: http.RequestMethod.GET,
          header: header,
          connectTimeout: CONNECT_TIMEOUT_MS,
          readTimeout: READ_TIMEOUT_MS,
          expectDataType: http.HttpDataType.ARRAY_BUFFER
        });
      } catch (e) {
        throw new ProfileError('network', (e as Error).message);
      }
      if (response.responseCode !== 200) {
        throw new ProfileError('http', `${response.responseCode}`);
      }
      try {
        await writeBuffer(path, response.result as ArrayBuffer);
      } catch (e) {
        throw new ProfileError('io', (e as Error).message);
      }
      return infoFromHeaders(lowerCaseHeaders(response.header));
    } finally {
      request.destroy();
    }
  }
}
