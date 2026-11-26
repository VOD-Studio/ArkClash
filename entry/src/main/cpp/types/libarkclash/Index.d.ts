/** 无 TUN 启动核心；参数见 core/lifecycle.go，失败时 reject。 */
export const start: (optionsJson: string) => Promise<void>;
export const stop: () => Promise<void>;
export const reclaimMemory: () => Promise<boolean>;
export const attachTun: (fd: number, optionsJson: string, bootId: string, profile: string, configRevision: number) => Promise<void>;
export const detachTun: () => Promise<void>;
export const updateVpnState: (intent: string, forward: string, vpnCreated: boolean) => Promise<void>;
export const runtimeStatus: () => Promise<string>;
/** path/profile 同为空可清空已断开的配置；expectedProfile 空串只接受空核心，省略则不约束。 */
export const reload: (path: string, profile: string, expectedProfile?: string) => Promise<void>;
/** 经内核下载，请求和结果 JSON 见 core/api.go 的 fetchRequest、fetchResult。 */
export const fetch: (requestJson: string) => Promise<string>;
/** 预先下载 path 里本地还没有的 rule-provider，结果 JSON 见 core/api.go 的 prefetchResult。 */
export const prefetch: (path: string) => Promise<string>;
/** 正在运行的配置编号（界面发起的热切换也会更新它），没在运行时是空串。 */
export const runningProfile: () => string;
export const version: () => string;
/**
 * 登记 profile/vpn 命令的唯一处理函数；name 为 profiles/* 或 vpn/*，在 ArkTS 线程上调用。
 * 每条命令都要用 reply 回复同一个 id；再次调用会替换之前的处理函数。
 */
export const onCommand: (handler: (id: number, name: string, body: string) => void) => void;
export const reply: (id: number, status: number, body: string) => void;
/** 推一条事件（JSON 对象）给订阅 /arkclash/events 的界面。 */
export const emit: (eventJson: string) => void;
