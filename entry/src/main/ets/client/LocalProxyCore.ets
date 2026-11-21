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

interface RuntimeProxyDefinitionRequest {
  bootId: string;
  configRevision: number;
  id: string;
  group: string;
}

export interface RuntimeProxyDefinition {
  bootId: string;
  configRevision: number;
  id: string;
  name: string;
  provider?: string;
  definition: ProxyDefinition;
}

const RUNTIME_PROXY_ERRORS: string[] = [
  'core_not_running', 'core_profile_unavailable', 'proxy_stale_config',
  'proxy_not_found', 'proxy_not_exportable', 'proxy_invalid_request'
];

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

export async function fetchRuntimeProxyDefinition(filesDir: string, bootId: string, configRevision: number,
  id: string, group: string): Promise<RuntimeProxyDefinition> {
  const body: RuntimeProxyDefinitionRequest = {
    bootId: bootId,
    configRevision: configRevision,
    id: id,
    group: group
  };
  try {
    const response = await call(filesDir, http.RequestMethod.POST, '/arkclash/proxies/definition',
      JSON.stringify(body), 10000);
    const parsed = JSON.parse(response) as RuntimeProxyDefinition;
    if (parsed === null || parsed === undefined || typeof parsed !== 'object' ||
      typeof parsed.id !== 'string' || parsed.id !== id ||
      typeof parsed.bootId !== 'string' || parsed.bootId !== bootId ||
      parsed.configRevision !== configRevision ||
      parsed.definition === null || parsed.definition === undefined || typeof parsed.definition !== 'object') {
      throw new Error('proxy_not_exportable');
    }
    return parsed;
  } catch (error) {
    const message = (error as Error).message;
    throw new Error(RUNTIME_PROXY_ERRORS.includes(message) ? message : 'local_proxy_core_unavailable');
  }
}
