import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { DirectDownloader } from '../shared/profiles/Download';
import { iconSetLoopback, IconSetDownloadCommand, IconSetSnapshot, validIconSetUrl } from '../shared/profiles/IconSetModel';
import { downloadIconSet, readIconSets } from '../shared/profiles/IconSets';
import { newId } from '../shared/profiles/Store';
import { call } from './Controller';
import { readCoreHostStatus } from './CoreClient';

export async function fetchIconSet(context: common.UIAbilityContext, expected: IconSetSnapshot, source: string,
  label: string, id: string = ''): Promise<IconSetSnapshot> {
  if (!validIconSetUrl(source)) { throw new Error('icon_set_input'); }
  const command: IconSetDownloadCommand = { expectedRevision: expected.revision, revision: newId('r'),
    id: id, name: label, url: source };
  const filesDir = context.filesDir;
  if (!iconSetLoopback(source)) {
    const host = await readCoreHostStatus(context);
    if (host.state === 'unknown') { throw new Error('host_unknown'); }
    if (host.status?.forward === 'running') {
      try {
        await call(filesDir, http.RequestMethod.POST, '/arkclash/profiles/icon-set-download',
          JSON.stringify(command), 35000);
      } catch (error) {
        const saved = await readIconSets(filesDir).catch((): undefined => undefined);
        if (saved?.revision !== command.revision) { throw error as Error; }
        return saved;
      }
      return readIconSets(filesDir);
    }
  }
  return downloadIconSet(filesDir, new DirectDownloader(), command);
}
