import { http } from '@kit.NetworkKit';
import { CONTROLLER_ADDRESS, readRuntime } from './Runtime';

const TIMEOUT_MS = 3000;

interface ErrorBody {
  message?: string;
}

/** 非 2xx 时抛出 Error，message 优先用响应里的 message（ArkClash 自有接口的错误格式）。 */
export async function call(filesDir: string, method: http.RequestMethod, path: string, body?: string,
  timeoutMs: number = TIMEOUT_MS, maxLimit?: number): Promise<string> {
  const runtime = await readRuntime(filesDir);
  if (runtime === undefined) {
    throw new Error('core is not running');
  }
  const request = http.createHttp();
  try {
    const header: Record<string, string> = {
      'Authorization': `Bearer ${runtime.secret}`,
      'Content-Type': 'application/json'
    };
    const options: http.HttpRequestOptions = {
      method: method,
      header: header,
      extraData: body,
      connectTimeout: TIMEOUT_MS,
      readTimeout: timeoutMs,
      expectDataType: http.HttpDataType.STRING
    };
    if (maxLimit !== undefined) {
      options.maxLimit = maxLimit;
    }
    const response = await request.request(`http://${CONTROLLER_ADDRESS}${path}`, options);
    if (response.responseCode < 200 || response.responseCode >= 300) {
      let message: string | undefined;
      try {
        message = (JSON.parse(response.result as string) as ErrorBody).message;
      } catch (e) {
        message = undefined;
      }
      throw new Error(message ?? `controller ${path}: HTTP ${response.responseCode}`);
    }
    return response.result as string;
  } finally {
    request.destroy();
  }
}
