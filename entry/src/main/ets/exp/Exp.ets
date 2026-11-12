// 阶段 0 真机实验的界面进程一侧，只存在于实验分支，不合并。
// 用 `aa start -a EntryAbility -b <bundle> --ps exp <动作>` 触发，结果打到 hilog 的 ArkClashExp 标签。
import { common } from '@kit.AbilityKit';
import { process, util } from '@kit.ArkTS';
import { http, socket } from '@kit.NetworkKit';
import { call } from '../client/Controller';
import { probeCore, startCore, stopCore } from '../client/CoreClient';
import { expLog, memoryText } from '../shared/ExpLog';
import { hasFile } from '../shared/Files';
import { readList, yamlPath } from '../shared/profiles/Store';

const SOCKET_TIMEOUT_MS = 3000;
// 界面进程里加载的内核用另一个端口，不和 VPN 进程的 controller 冲突。
const LOCAL_CONTROLLER = '127.0.0.1:19091';

interface LocalCoreOptions {
  homeDir: string;
  configPath: string;
  tunFd: number;
  controller: string;
  secret: string;
  stack: string;
  profile: string;
  mode: string;
  standby: boolean;
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, ms));
}

// 实验四：连 VPN 进程里内核监听的 Unix 套接字，发一行、收一行。
function sockPing(filesDir: string): Promise<string> {
  const client: socket.LocalSocket = socket.constructLocalSocketInstance();
  return new Promise<string>((resolve: (text: string) => void, reject: (e: Error) => void) => {
    const timer = setTimeout(() => {
      client.close().catch(() => {});
      reject(new Error('timeout'));
    }, SOCKET_TIMEOUT_MS);
    client.on('message', (info: socket.LocalSocketMessageInfo) => {
      clearTimeout(timer);
      const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(info.message));
      client.close().catch(() => {});
      resolve(text.trim());
    });
    const options: socket.LocalConnectOptions = {
      address: { address: `${filesDir}/exp.sock` },
      timeout: SOCKET_TIMEOUT_MS
    };
    client.connect(options).then(() => {
      const data: socket.LocalSendOptions = { data: 'ping\n' };
      return client.send(data);
    }).catch((e: Error) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

// 实验五：界面进程自己加载内核并以待机方式装好配置，看内存涨多少。只在 VPN 进程没跑时做。
async function loadCore(filesDir: string): Promise<void> {
  expLog('ui', `event=mem stage=before-import ${memoryText()}`);
  const t0 = Date.now();
  const ns = await import('libarkclash.so');
  expLog('ui', `event=mem stage=after-import import_ms=${Date.now() - t0} ${memoryText()}`);
  const profile = readList(filesDir).current;
  if (profile === '' || !hasFile(yamlPath(filesDir, profile))) {
    throw new Error('no profile selected');
  }
  const options: LocalCoreOptions = {
    homeDir: filesDir,
    configPath: yamlPath(filesDir, profile),
    tunFd: 0,
    controller: LOCAL_CONTROLLER,
    secret: 'exp',
    stack: 'gvisor',
    profile: profile,
    mode: '',
    standby: true
  };
  const t1 = Date.now();
  const started: Promise<void> = ns.default.start(JSON.stringify(options));
  await started;
  expLog('ui', `event=mem stage=after-start start_ms=${Date.now() - t1} version=${ns.default.version()} ${memoryText()}`);
  await sleep(10000);
  expLog('ui', `event=mem stage=after-start-10s ${memoryText()}`);
}

async function run(context: common.UIAbilityContext, name: string): Promise<string> {
  const filesDir = context.filesDir;
  switch (name) {
    case 'cold':
      return `version=${await startCore(context, '', undefined)}`;
    case 'standby':
      return `version=${await startCore(context, '', undefined, true)}`;
    case 'attach':
      return await call(filesDir, http.RequestMethod.POST, '/arkclash/profiles/exp-attach', '{}', 30000);
    case 'vpnpss':
      return await call(filesDir, http.RequestMethod.POST, '/arkclash/profiles/exp-pss', '{}');
    case 'stop':
      await stopCore(context);
      return 'stopped';
    case 'probe':
      return `version=${(await probeCore(context)) ?? 'none'}`;
    case 'sock':
      return `reply=${await sockPing(filesDir)}`;
    case 'pss':
      return memoryText();
    case 'loadcore':
      await loadCore(filesDir);
      return 'loaded';
    case 'die':
      // 模拟界面进程被系统强杀。
      new process.ProcessManager().kill(9, process.pid);
      return 'unreachable';
    default:
      throw new Error(`unknown experiment ${name}`);
  }
}

export async function runExperiment(context: common.UIAbilityContext, name: string): Promise<void> {
  const t0 = Date.now();
  expLog('ui', `event=exp-begin name=${name}`);
  try {
    const result = await run(context, name);
    expLog('ui', `event=exp-end name=${name} ok=true ms=${Date.now() - t0} ${result}`);
  } catch (e) {
    expLog('ui', `event=exp-end name=${name} ok=false ms=${Date.now() - t0} err=${(e as Error).message}`);
  }
}
