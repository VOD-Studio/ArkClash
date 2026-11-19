import { http } from '@kit.NetworkKit';
import { call } from '../ControllerRequest';
import { ConfigScriptsSnapshot, readConfigScripts, scriptIdentity } from './Scripts';
import { readListAsync, withProfileTask, yamlPath } from './Store';

interface ScriptRuntimeIdentity {
  bootId: string;
  profile: string;
  running: boolean;
  profileExtension?: string;
  standardRulesRevision?: string;
}

interface ScriptApplyRequest {
  bootId: string;
  profile: string;
  identity: string;
  standardRevision?: string;
}

interface ScriptReloadRequest {
  profile: string;
  path: string;
  expectedProfile: string;
}

export async function applyConfigScript(filesDir: string, store: ConfigScriptsSnapshot, profile: string,
  changedScript: string = '', standardRevision: string = ''): Promise<boolean> {
  const selected = (await readListAsync(filesDir)).current;
  const active = profile || selected;
  if (active === '' || active !== selected) { return false; }
  const identity = scriptIdentity(store, active);
  if (changedScript !== '' && !(identity ?? '').startsWith(`script:${changedScript}:`)) { return false; }
  if (identity === undefined) { throw new Error('script_missing'); }
  return withProfileTask<boolean>(filesDir, active, async (): Promise<boolean> => {
    let status: ScriptRuntimeIdentity;
    try {
      const text = await call(filesDir, http.RequestMethod.GET, '/arkclash/status');
      status = JSON.parse(text) as ScriptRuntimeIdentity;
    } catch (error) { return false; }
    if (!status.running || (await readListAsync(filesDir)).current !== active) { return false; }
    if (scriptIdentity(await readConfigScripts(filesDir), active) !== identity) { throw new Error('script_conflict'); }
    if (active !== status.profile) {
      const request: ScriptReloadRequest = { profile: active, path: yamlPath(filesDir, active),
        expectedProfile: status.profile };
      await call(filesDir, http.RequestMethod.POST, '/arkclash/reload', JSON.stringify(request), 60000);
    } else if (identity !== (status.profileExtension ?? '') ||
      (identity === '' && standardRevision !== (status.standardRulesRevision ?? ''))) {
      const request: ScriptApplyRequest = { bootId: status.bootId, profile: active, identity: identity,
        standardRevision: identity === '' ? standardRevision : undefined };
      await call(filesDir, http.RequestMethod.POST, '/arkclash/scripts/apply', JSON.stringify(request), 60000);
    }
    return true;
  });
}
