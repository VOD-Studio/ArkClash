import { readGeoSettings } from '../shared/GeoResources';
import { applyConfigScript } from '../shared/profiles/ScriptApply';
import { ConfigScript, downloadConfigScript, readConfigScripts, ScriptDownloadCommand } from '../shared/profiles/Scripts';
import { Downloader } from '../shared/profiles/Download';
import { KernelDownloader } from './KernelDownloader';

const HOUR_MS = 3600000;

export async function refreshDueScripts(filesDir: string, eligible: () => boolean): Promise<void> {
  const settings = await readGeoSettings(filesDir);
  if (!settings.autoUpdate || !eligible()) { return; }
  const scripts = await readConfigScripts(filesDir);
  const downloader = new KernelDownloader();
  for (const item of scripts.scripts) {
    if (!eligible()) { return; }
    if (item.url === '' || item.updatedAt + settings.intervalHours * HOUR_MS > Date.now()) { continue; }
    try {
      if (!(await readGeoSettings(filesDir)).autoUpdate) { return; }
      const saved = await downloadConfigScript(filesDir, downloader, item.url, item, eligible);
      if (eligible()) { await applyConfigScript(filesDir, saved, '', item.id); }
    } catch (error) {
      // 保留旧正文或最后可运行配置。脚本、URL 及用户可控异常不写日志。
    }
  }
}

interface ScriptDownloadReply { ok: boolean; }

export async function handleScriptDownload(filesDir: string, downloader: Downloader, body: string,
  eligible: () => boolean): Promise<ScriptDownloadReply> {
  const request = JSON.parse(body) as ScriptDownloadCommand;
  if (typeof request.id !== 'string' || typeof request.revision !== 'string' || typeof request.url !== 'string') {
    throw new Error('url_invalid');
  }
  let expected: ConfigScript | undefined;
  if (request.id !== '') {
    const store = await readConfigScripts(filesDir);
    expected = store.scripts.find((item: ConfigScript): boolean => item.id === request.id);
    if (expected === undefined || expected.revision !== request.revision) { throw new Error('script_conflict'); }
  }
  await downloadConfigScript(filesDir, downloader, request.url, expected, eligible);
  return { ok: true };
}
