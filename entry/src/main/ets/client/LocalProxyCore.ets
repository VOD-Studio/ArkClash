import { common } from '@kit.AbilityKit';
import { taskpool } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { connection } from './Connection';
import { call } from '../shared/ControllerRequest';
import { ProxyDefinition } from '../shared/profiles/LocalProxySchema';

interface LocalProxyRequest {
  definitions?: ProxyDefinition[];
  lines?: string[];
}

@Concurrent
function encode(body: LocalProxyRequest): string { return JSON.stringify(body); }

@Concurrent
function decodeChecks(text: string): string[] { return JSON.parse(text) as string[]; }

@Concurrent
function decodeLinks(text: string): ProxyDefinition[][] { return JSON.parse(text) as ProxyDefinition[][]; }

async function prepareProxyCore(context: common.UIAbilityContext): Promise<void> {
  let timer = -1;
  try {
    await Promise.race<void>([connection.ensureReady(context), new Promise<void>((_resolve, reject): void => {
      timer = setTimeout((): void => reject(new Error('local_proxy_core_unavailable')), 6000);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

async function proxyRequest(context: common.UIAbilityContext, action: string, body: LocalProxyRequest,
  wake: boolean): Promise<string> {
  const encoded = await taskpool.execute(encode, body) as string;
  const path = `/arkclash/local-proxies/${action}`;
  try {
    return await call(context.filesDir, http.RequestMethod.POST, path, encoded, 15000);
  } catch (error) {
    if ((error as Error).message === 'local_proxy_input') { throw error as Error; }
  }
  if (wake) {
    try {
      await prepareProxyCore(context);
      return await call(context.filesDir, http.RequestMethod.POST, path, encoded, 15000);
    } catch (error) {
      if ((error as Error).message === 'local_proxy_input') { throw error as Error; }
    }
  }
  throw new Error('local_proxy_core_unavailable');
}

export async function validateProxyDefinitions(context: common.UIAbilityContext, definitions: ProxyDefinition[],
  wake: boolean = false): Promise<string[]> {
  if (definitions.length === 0) { return []; }
  const response = await proxyRequest(context, 'validate', { definitions: definitions }, wake);
  return await taskpool.execute(decodeChecks, response) as string[];
}

export async function encodeProxyLinks(context: common.UIAbilityContext,
  definitions: ProxyDefinition[],
  wake: boolean = true): Promise<string[]> {
  if (definitions.length === 0) { return []; }
  const response = await proxyRequest(context, 'encode', { definitions: definitions }, wake);
  return await taskpool.execute(decodeChecks, response) as string[];
}

export async function decodeProxyLinks(context: common.UIAbilityContext, lines: string[]): Promise<ProxyDefinition[][]> {
  if (lines.length === 0) { return []; }
  const response = await proxyRequest(context, 'decode', { lines: lines }, true);
  return await taskpool.execute(decodeLinks, response) as ProxyDefinition[][];
}
