/** Starts the core; rejects with the core's error message. Options: see core/lib.go startOptions. */
export const start: (optionsJson: string) => Promise<void>;
export const stop: () => Promise<void>;
/** 实验：给待机中的内核（start 时 standby 为 true）接上隧道。 */
export const attachTun: (fd: number, stack: string) => Promise<void>;
/** 热切换到 path（必须在 filesDir/profiles/ 下）；解析失败时 reject，内核保持原样。 */
export const reload: (path: string, profile: string) => Promise<void>;
/** 经内核下载，请求和结果 JSON 见 core/api.go 的 fetchRequest、fetchResult。 */
export const fetch: (requestJson: string) => Promise<string>;
/** 预先下载 path 里本地还没有的 rule-provider，结果 JSON 见 core/api.go 的 prefetchResult。 */
export const prefetch: (path: string) => Promise<string>;
/** 正在运行的配置编号（界面发起的热切换也会更新它），没在运行时是空串。 */
export const runningProfile: () => string;
export const version: () => string;
/**
 * 登记订阅类命令（POST /arkclash/profiles/{name}）的处理函数，在 ArkTS 线程上调用。
 * 每条命令都要用 reply 回复同一个 id；再次调用会替换之前的处理函数。
 */
export const onCommand: (handler: (id: number, name: string, body: string) => void) => void;
export const reply: (id: number, status: number, body: string) => void;
/** 推一条事件（JSON 对象）给订阅 /arkclash/events 的界面。 */
export const emit: (eventJson: string) => void;
