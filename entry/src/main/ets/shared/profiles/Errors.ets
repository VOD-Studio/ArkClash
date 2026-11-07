// 写进状态文件和命令回复的错误：`代码` 或 `代码:说明`。状态文件可能由 VPN 进程写，
// 不放本地化文字，界面按代码显示（features/profiles/ProfileErrors.ets）。
//   http          服务器返回非 200，说明是状态码
//   not_clash     不是 Clash 配置：顶层没有 proxies 和 proxy-providers
//   invalid_yaml  YAML 解析失败，说明是解析器给的第一行
//   rejected      内核解析失败（只在正在运行的配置上检查），说明是内核的错误信息
//   network       网络错误，说明是系统给的信息
//   io            读写文件失败
//   not_found     订阅或配置不在列表里
//   busy          这个订阅正在更新
export class ProfileError extends Error {
  constructor(code: string, detail?: string) {
    super(detail !== undefined && detail.length > 0 ? `${code}:${detail}` : code);
  }
}

const CODES: string[] = ['http', 'not_clash', 'invalid_yaml', 'rejected', 'network', 'io', 'not_found', 'busy'];

/** 已经带代码的原样返回，其余的当网络错误。 */
export function errorString(e: Object): string {
  const message = (e as Error).message ?? `${e}`;
  const code = message.split(':')[0];
  return CODES.includes(code) ? message : `network:${message}`;
}

export function errorCode(error: string): string {
  return error.split(':')[0];
}

export function errorDetail(error: string): string {
  const i = error.indexOf(':');
  return i < 0 ? '' : error.substring(i + 1);
}
