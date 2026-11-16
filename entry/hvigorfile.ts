import { getNode, HvigorNode } from '@ohos/hvigor';
import { hapTasks, OhosHapContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';

getNode(__filename).afterNodeEvaluate((node: HvigorNode) => {
  const abi = process.env.ABI ?? 'arm64-v8a';
  if (abi !== 'arm64-v8a' && abi !== 'x86_64') {
    throw new Error(`不支持的 ABI：${abi}（仅支持 arm64-v8a、x86_64）`);
  }
  const hapContext = node.getContext(OhosPluginId.OHOS_HAP_PLUGIN) as OhosHapContext;
  const profile = hapContext.getBuildProfileOpt();
  const buildOption = profile.buildOption ?? {};
  buildOption.externalNativeOptions = {
    ...buildOption.externalNativeOptions,
    abiFilters: [abi]
  };
  // CMake 的 abiFilters 不过滤预编译库；打包时用 minimatch 排除非选中 ABI。
  const nativeLib = buildOption.nativeLib ?? {};
  nativeLib.filter = {
    ...nativeLib.filter,
    excludes: [...(nativeLib.filter?.excludes ?? []), `!${abi}/**`]
  };
  buildOption.nativeLib = nativeLib;
  profile.buildOption = buildOption;
  hapContext.setBuildProfileOpt(profile);
});

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: []       /* Custom plugin to extend the functionality of Hvigor. */
}