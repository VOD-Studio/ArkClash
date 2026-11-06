import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { hasFile, profilePath, writeText } from './Runtime';

// Subscriptions return Clash YAML only for clients they recognise.
const USER_AGENT = 'clash.meta';

/** Downloads a subscription into the default profile and returns its size in bytes. */
export async function downloadProfile(filesDir: string, url: string): Promise<number> {
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
    const text = response.result as string;
    const dir = `${filesDir}/profiles`;
    if (!hasFile(dir)) {
      fs.mkdirSync(dir);
    }
    writeText(profilePath(filesDir), text);
    return text.length;
  } finally {
    request.destroy();
  }
}

export function hasProfile(filesDir: string): boolean {
  return hasFile(profilePath(filesDir));
}
