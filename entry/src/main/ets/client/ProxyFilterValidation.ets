import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { call, getRuntimeStatus } from './Controller';
import { connection } from './Connection';

interface ProxyFilterValidationResult {
  invalidPart: number;
}

interface ProxyFilterValidationRequest {
  expression: string;
}

export async function checkProxyFilter(context: common.UIAbilityContext, expression: string): Promise<number> {
  const status = await getRuntimeStatus(context.filesDir).catch((): undefined => undefined);
  if (status?.running !== true) {
    try {
      await connection.ensureReady(context);
    } catch (_error) {
      throw new Error('proxy_filter_core');
    }
  }
  const payload: ProxyFilterValidationRequest = { expression: expression };
  try {
    const result = await call(context.filesDir, http.RequestMethod.POST, '/arkclash/proxy-filters/validate',
      JSON.stringify(payload));
    const checked = JSON.parse(result) as ProxyFilterValidationResult;
    if (Number.isInteger(checked.invalidPart) && checked.invalidPart >= 0) {
      return checked.invalidPart;
    }
  } catch (_error) {
    throw new Error('proxy_filter_core');
  }
  throw new Error('proxy_filter_core');
}
