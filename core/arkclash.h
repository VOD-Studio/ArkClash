// C API exported by libclash.so (core/lib.go). Keep the two in sync.
#ifndef ARKCLASH_CORE_H
#define ARKCLASH_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Starts the core with a JSON options object. Returns NULL on success or an
// error message to release with ArkClashFree.
char *ArkClashStart(char *optionsJSON);
void ArkClashStop(void);
// 热切换到 path 指向的配置（必须在 filesDir/profiles/ 下），profile 是它的编号。
// 成功返回 NULL，否则返回错误信息，用 ArkClashFree 释放。
char *ArkClashReload(char *path, char *profile);
// 预先下载 path（配置目录下的文件）里本地还没有的 rule-provider，第一次热切换到它时不用等。
// 返回 JSON {"downloaded":n} 或 {"error":"..."}；会阻塞，只能在工作线程上调用；用 ArkClashFree 释放。
char *ArkClashPrefetch(char *path);
// 经内核下载，参数和结果都是 JSON（core/api.go 的 fetchRequest、fetchResult）。
// 会阻塞到请求结束，只能在工作线程上调用；结果用 ArkClashFree 释放。
char *ArkClashFetch(char *requestJSON);

// 订阅类命令的回调：Go 收到 POST /arkclash/profiles/{name} 后在自己的线程上调用。
// name 和 body 只在回调期间有效；处理完用 ArkClashReply 回复同一个 id。
typedef void (*ArkClashCommandHandler)(long long id, const char *name, const char *body);
void ArkClashSetCommandHandler(ArkClashCommandHandler handler);
// status 是 HTTP 状态码，body 是 JSON；body 的所有权留在调用方。
void ArkClashReply(long long id, int status, char *body);
// 推一条事件（JSON 对象）给订阅 /arkclash/events 的界面；所有权留在调用方。
void ArkClashEmit(char *eventJSON);
// 正在运行的配置编号，没在运行时是空串；用 ArkClashFree 释放。
char *ArkClashRunningProfile(void);
// Returns the mihomo version; release with ArkClashFree.
char *ArkClashVersion(void);
void ArkClashFree(char *p);

#ifdef __cplusplus
}
#endif

#endif // ARKCLASH_CORE_H
