import core from 'libarkclash.so';
import { CONNECT_TIMEOUT_MS, DirectDownloader, DownloadInfo, Downloader, infoFromHeaders, READ_TIMEOUT_MS,
  USER_AGENT } from '../shared/profiles/Download';
import { errorCode, errorString, ProfileError } from '../shared/profiles/Errors';

// 和 core/api.go 的 fetchRequest、fetchResult 一致。
interface FetchRequest {
  url: string;
  header: Record<string, string>;
  path: string;
  timeoutMs: number;
}

interface FetchResult {
  status: number;
  header?: Record<string, string>;
  error?: string;
}

/**
 * 连接中的订阅下载：先经内核按规则发出，不依赖配置有没有开代理端口；失败再直连一次，
 * 订阅到期、节点全挂时只有直连拿得到续费后的订阅（ADR-0009）。
 */
export class KernelDownloader implements Downloader {
  private direct: DirectDownloader = new DirectDownloader();

  async download(url: string, path: string): Promise<DownloadInfo> {
    let kernelError: ProfileError;
    try {
      const request: FetchRequest = {
        url: url,
        header: { 'User-Agent': USER_AGENT },
        path: path,
        timeoutMs: CONNECT_TIMEOUT_MS + READ_TIMEOUT_MS
      };
      // 先赋给带类型的变量再 await：codelinter 解析不到 .so 的类型声明，直接 await 会误报 await-thenable。
      const pending: Promise<string> = core.fetch(JSON.stringify(request));
      const result = JSON.parse(await pending) as FetchResult;
      if (result.error === undefined && result.status === 200) {
        return infoFromHeaders(result.header ?? {});
      }
      kernelError = result.error !== undefined ? new ProfileError('network', result.error) :
        new ProfileError('http', `${result.status}`);
    } catch (e) {
      kernelError = new ProfileError('network', (e as Error).message);
    }
    try {
      return await this.direct.download(url, path);
    } catch (e) {
      // 两条路都失败时，服务器给过状态码的那条更能说明问题。
      if (errorCode(errorString(kernelError)) === 'http') {
        throw kernelError;
      }
      throw e as Error;
    }
  }
}
