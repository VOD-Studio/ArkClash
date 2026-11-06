import { getNode, HvigorNode } from '@ohos/hvigor';
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';

// versionCode 由 versionName 算出（major*1000000 + minor*1000 + patch），
// 版本号只维护 AppScope/app.json5 的 versionName 一处，发版时由 release-please 更新。
function versionCodeOf(versionName: string): number {
  const m = /^(\d+)\.(\d+)\.(\d+)/.exec(versionName);
  if (m === null) {
    throw new Error(`versionName 必须是 x.y.z：${versionName}`);
  }
  return Number(m[1]) * 1000000 + Number(m[2]) * 1000 + Number(m[3]);
}

getNode(__filename).afterNodeEvaluate((node: HvigorNode) => {
  const appContext = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
  const appJson = appContext.getAppJsonOpt();
  appJson.app.versionCode = versionCodeOf(appJson.app.versionName);
  appContext.setAppJsonOpt(appJson);
});

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: []       /* Custom plugin to extend the functionality of Hvigor. */
}
