import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { hasFile, profilePath, writeText } from '../../shared/Runtime';

// Subscriptions return Clash YAML only for clients they recognise.
const USER_AGENT = 'clash.meta';

// 多订阅（#35）定下来之前，只有一份来自订阅的配置，元数据放在 preferences 里。
const PREF_URL = 'subscriptionUrl';
const PREF_NAME = 'profileName';
const PREF_UPDATED_AT = 'profileUpdatedAt';
const PREF_USAGE = 'profileUsage';

/** 机场在 subscription-userinfo 头里给的用量，字节；expire 是秒级时间戳，0 = 未知或不过期。 */
export interface SubscriptionUsage {
  upload: number;
  download: number;
  total: number;
  expire: number;
}

interface DownloadResult {
  text: string;
  name: string;
  usage?: SubscriptionUsage;
}

function headerValue(headers: Object, name: string): string | undefined {
  const record = headers as Record<string, string | string[]>;
  for (const key of Object.keys(record)) {
    if (key.toLowerCase() === name) {
      const value = record[key];
      return typeof value === 'string' ? value : value[0];
    }
  }
  return undefined;
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
  return name?.replace(/\.(ya?ml|txt)$/i, '');
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

function hostOf(url: string): string {
  const match = /^[a-z]+:\/\/([^/:?#]+)/i.exec(url);
  return match !== null ? match[1] : url;
}

async function downloadSubscription(url: string): Promise<DownloadResult> {
  const request = http.createHttp();
  try {
    const header: Record<string, string> = { 'User-Agent': USER_AGENT };
    const response = await request.request(url, {
      method: http.RequestMethod.GET,
      header: header,
      connectTimeout: 15000,
      readTimeout: 30000,
      expectDataType: http.HttpDataType.STRING
    });
    if (response.responseCode !== 200) {
      throw new Error(`HTTP ${response.responseCode}`);
    }
    return {
      text: response.result as string,
      name: nameFromDisposition(headerValue(response.header, 'content-disposition')) ?? hostOf(url),
      usage: parseUsage(headerValue(response.header, 'subscription-userinfo'))
    };
  } finally {
    request.destroy();
  }
}

function saveProfile(filesDir: string, text: string): void {
  const dir = `${filesDir}/profiles`;
  if (!hasFile(dir)) {
    fs.mkdirSync(dir);
  }
  writeText(profilePath(filesDir), text);
}

/** 当前配置的元数据。首帧直接从 preferences 读，不碰网络。 */
@ObservedV2
export class ProfileStore {
  @Trace url: string = '';
  @Trace name: string = '';
  @Trace ready: boolean = false;
  @Trace updatedAt: number = 0;
  @Trace usage: SubscriptionUsage | undefined = undefined;
  @Trace downloading: boolean = false;
  @Trace error: string = '';
  private prefs?: preferences.Preferences;
  private filesDir: string = '';

  load(context: common.UIAbilityContext): void {
    this.filesDir = context.filesDir;
    this.prefs = preferences.getPreferencesSync(context, { name: 'settings' });
    this.url = this.prefs.getSync(PREF_URL, '') as string;
    this.ready = hasFile(profilePath(this.filesDir));
    this.name = this.prefs.getSync(PREF_NAME, '') as string;
    if (this.name.length === 0 && this.url.length > 0) {
      this.name = hostOf(this.url);
    }
    this.updatedAt = this.prefs.getSync(PREF_UPDATED_AT, 0) as number;
    const usage = this.prefs.getSync(PREF_USAGE, '') as string;
    this.usage = usage.length > 0 ? JSON.parse(usage) as SubscriptionUsage : undefined;
  }

  /** 下载订阅并替换当前配置；失败时保留原来的配置，错误放在 error。 */
  async download(url: string): Promise<boolean> {
    if (this.downloading) {
      return false;
    }
    this.downloading = true;
    this.error = '';
    try {
      const result = await downloadSubscription(url);
      saveProfile(this.filesDir, result.text);
      this.url = url;
      this.name = result.name;
      this.usage = result.usage;
      this.updatedAt = Date.now();
      this.ready = true;
      this.prefs?.putSync(PREF_URL, url);
      this.prefs?.putSync(PREF_NAME, result.name);
      this.prefs?.putSync(PREF_UPDATED_AT, this.updatedAt);
      this.prefs?.putSync(PREF_USAGE, result.usage !== undefined ? JSON.stringify(result.usage) : '');
      this.prefs?.flush();
      return true;
    } catch (e) {
      this.error = (e as Error).message;
      return false;
    } finally {
      this.downloading = false;
    }
  }
}
