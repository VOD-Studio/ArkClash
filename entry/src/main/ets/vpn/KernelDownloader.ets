import { generalUserAgent } from '../shared/GeneralSettings';
import core from 'libarkclash.so';
import { DOWNLOAD_TIMEOUT_MS, DownloadInfo, DownloadRequestIdentity, Downloader, infoFromHeaders,
  prepareDownloadAddress } from '../shared/profiles/Download';
import { errorString, ProfileError } from '../shared/profiles/Errors';

// 和 core/api.go 的 fetchRequest、fetchResult 一致。
interface FetchRequest {
  url: string;
  header: Record<string, string>;
  path: string;
  timeoutMs: number;
  maxBytes?: number;
  ageSecretKey?: string;
}

interface FetchResult {
  status: number;
  header?: Record<string, string>;
  error?: string;
}

// 在线订阅按当前规则经内核下载；失败保留原配置，不改变用户选择的出口策略。
export class KernelDownloader implements Downloader {
  private filesDir: string;

  constructor(filesDir: string) { this.filesDir = filesDir; }

  async download(url: string, path: string, identity?: DownloadRequestIdentity): Promise<DownloadInfo> {
    if (identity?.canceled()) {
      throw new ProfileError('canceled');
    }
    const address = await prepareDownloadAddress(url, await generalUserAgent(this.filesDir));
    const request: FetchRequest = {
      url: address.address,
      header: address.headers,
      path: path,
      timeoutMs: DOWNLOAD_TIMEOUT_MS, maxBytes: identity?.maxBytes, ageSecretKey: identity?.ageSecretKey
    };
    try {
      const pending: Promise<string> = core.fetch(JSON.stringify(request));
      const result = JSON.parse(await pending) as FetchResult;
      if (identity?.canceled()) {
        throw new ProfileError('canceled');
      }
      if (result.error !== undefined) {
        throw new ProfileError(errorString(new Error(result.error)));
      }
      if (result.status !== 200) {
        throw new ProfileError('http', `${result.status}`);
      }
      return infoFromHeaders(result.header ?? {});
    } catch (error) {
      throw new ProfileError(errorString(error as Error));
    }
  }
}
