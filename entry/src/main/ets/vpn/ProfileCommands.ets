// 连接中界面经 controller 发来的订阅类命令（POST /arkclash/profiles/{name}），由 Go 转到这里（ADR-0009）。
// 请求和回复的格式与 entry/src/main/ets/client/ProfileCommands.ets 一致。
import core from 'libarkclash.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { errorString } from '../shared/profiles/Errors';
import { downloadNewSubscription, UpdateEnv, UpdateOutcome, UpdateScheduler } from '../shared/profiles/Updater';

const DOMAIN = 0x0A11;
const TAG = 'ProfileCommands';

interface UpdateCommand {
  subscription: string;
  url?: string; // 修改链接时的新链接
}

interface AddCommand {
  profile: string;
  subscription: string;
  url: string;
}

interface ErrorReply {
  message: string;
}

interface OkReply {
  ok: boolean;
}

interface UpdatedEvent {
  type: string; // 'updated'
  subscription: string;
  ok: boolean;
}

function send(id: number, status: number, body: Object): void {
  core.reply(id, status, JSON.stringify(body));
}

/** 实验命令（exp- 开头）的处理函数，不认识的返回 undefined。 */
export type ExpHandler = (name: string) => Promise<Object> | undefined;

async function handle(scheduler: UpdateScheduler, env: UpdateEnv, name: string, body: string,
  exp?: ExpHandler): Promise<Object> {
  const expResult = exp?.(name);
  if (expResult !== undefined) {
    return await expResult;
  }
  switch (name) {
    case 'update': {
      const command = JSON.parse(body) as UpdateCommand;
      return await scheduler.update(command.subscription, command.url);
    }
    case 'add': {
      const command = JSON.parse(body) as AddCommand;
      return await downloadNewSubscription(env, command.profile, command.subscription, command.url);
    }
    case 'changed': {
      scheduler.reschedule();
      const reply: OkReply = { ok: true };
      return reply;
    }
    default:
      throw new Error(`unknown command ${name}`);
  }
}

/** 登记命令处理函数。每条命令都会回复，不管成功与否。 */
export function serveProfileCommands(scheduler: UpdateScheduler, env: UpdateEnv, exp?: ExpHandler): void {
  core.onCommand((id: number, name: string, body: string) => {
    handle(scheduler, env, name, body, exp).then((result: Object) => {
      send(id, 200, result);
    }).catch((e: Error) => {
      hilog.error(DOMAIN, TAG, 'command %{public}s failed: %{public}s', name, errorString(e));
      const reply: ErrorReply = { message: errorString(e) };
      send(id, 500, reply);
    });
  });
}

/** 推给界面：某个订阅更新完了，结果在它的状态文件里。 */
export function emitUpdated(outcome: UpdateOutcome): void {
  const event: UpdatedEvent = { type: 'updated', subscription: outcome.subscription, ok: outcome.ok };
  core.emit(JSON.stringify(event));
}
