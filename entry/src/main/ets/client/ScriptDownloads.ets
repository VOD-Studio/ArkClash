import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { DirectDownloader } from '../shared/profiles/Download';
import { ConfigScript, ConfigScriptsSnapshot, downloadConfigScript, isScriptLoopback, readConfigScripts,
  ScriptDownloadCommand } from '../shared/profiles/Scripts';
import { call } from './Controller';
import { readCoreHostStatus } from './CoreClient';

export async function fetchConfigScript(context: common.UIAbilityContext, url: string,
  item?: ConfigScript): Promise<ConfigScriptsSnapshot> {
  if (isScriptLoopback(url)) {
    return downloadConfigScript(context.filesDir, new DirectDownloader(context.filesDir), url, item);
  }
  const host = await readCoreHostStatus(context);
  if (host.state === 'unknown') { throw new Error('host_unknown'); }
  if (host.status?.forward === 'running') {
    const command: ScriptDownloadCommand = { id: item?.id ?? '', revision: item?.revision ?? '', url: url };
    await call(context.filesDir, http.RequestMethod.POST, '/arkclash/profiles/script-download', JSON.stringify(command), 30000);
    return readConfigScripts(context.filesDir);
  }
  return downloadConfigScript(context.filesDir, new DirectDownloader(context.filesDir), url, item);
}
