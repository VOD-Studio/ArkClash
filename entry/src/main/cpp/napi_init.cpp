// NAPI bridge between ArkTS and libclash.so. start/stop run on the libuv
// worker pool so the ArkTS thread never blocks on the core.
#include <string>

#include "arkclash.h"
#include "napi/native_api.h"

namespace {

enum class CoreCall { Start, Stop, Reload, Fetch, Prefetch, AttachTun };

struct CoreWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    CoreCall call = CoreCall::Stop;
    std::string arg0;
    std::string arg1;
    std::string error;
    std::string result; // fetch、prefetch 的结果 JSON
    int fd = 0;         // 实验：attachTun 的隧道 fd
};

// 返回值是 libclash.so 分配的字符串，复制后立即释放。
std::string TakeString(char *s)
{
    if (s == nullptr) {
        return "";
    }
    std::string copy = s;
    ArkClashFree(s);
    return copy;
}

void Execute(napi_env, void *data)
{
    auto *w = static_cast<CoreWork *>(data);
    switch (w->call) {
        case CoreCall::Start:
            w->error = TakeString(ArkClashStart(w->arg0.data()));
            break;
        case CoreCall::Stop:
            ArkClashStop();
            break;
        case CoreCall::Reload:
            w->error = TakeString(ArkClashReload(w->arg0.data(), w->arg1.data()));
            break;
        case CoreCall::Fetch:
            w->result = TakeString(ArkClashFetch(w->arg0.data()));
            break;
        case CoreCall::Prefetch:
            w->result = TakeString(ArkClashPrefetch(w->arg0.data()));
            break;
        case CoreCall::AttachTun:
            w->error = TakeString(ArkClashAttachTun(w->fd, w->arg0.data()));
            break;
    }
}

void Complete(napi_env env, napi_status, void *data)
{
    auto *w = static_cast<CoreWork *>(data);
    if (w->error.empty()) {
        napi_value value;
        if (w->call == CoreCall::Fetch || w->call == CoreCall::Prefetch) {
            napi_create_string_utf8(env, w->result.c_str(), w->result.size(), &value);
        } else {
            napi_get_undefined(env, &value);
        }
        napi_resolve_deferred(env, w->deferred, value);
    } else {
        napi_value msg;
        napi_value error;
        napi_create_string_utf8(env, w->error.c_str(), w->error.size(), &msg);
        napi_create_error(env, nullptr, msg, &error);
        napi_reject_deferred(env, w->deferred, error);
    }
    napi_delete_async_work(env, w->work);
    delete w;
}

napi_value Queue(napi_env env, CoreWork *w, const char *name)
{
    napi_value promise;
    napi_value resourceName;
    napi_create_promise(env, &w->deferred, &promise);
    napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resourceName);
    napi_create_async_work(env, nullptr, resourceName, Execute, Complete, w, &w->work);
    napi_queue_async_work(env, w->work);
    return promise;
}

bool GetString(napi_env env, napi_value value, std::string &out)
{
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    out.resize(len);
    napi_get_value_string_utf8(env, value, out.data(), len + 1, &len);
    return true;
}

// 读取 count 个字符串参数；类型不对时抛出 TypeError 并返回 false。
bool GetStringArgs(napi_env env, napi_callback_info info, size_t count, std::string *out, const char *usage)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    for (size_t i = 0; i < count; i++) {
        if (i >= argc || !GetString(env, args[i], out[i])) {
            napi_throw_type_error(env, nullptr, usage);
            return false;
        }
    }
    return true;
}

napi_value Start(napi_env env, napi_callback_info info)
{
    std::string args[1];
    if (!GetStringArgs(env, info, 1, args, "start(optionsJson: string) expects a string")) {
        return nullptr;
    }
    auto *w = new CoreWork();
    w->call = CoreCall::Start;
    w->arg0 = args[0];
    return Queue(env, w, "ArkClashStart");
}

napi_value Stop(napi_env env, napi_callback_info)
{
    return Queue(env, new CoreWork(), "ArkClashStop");
}

napi_value Reload(napi_env env, napi_callback_info info)
{
    std::string args[2];
    if (!GetStringArgs(env, info, 2, args, "reload(path: string, profile: string) expects strings")) {
        return nullptr;
    }
    auto *w = new CoreWork();
    w->call = CoreCall::Reload;
    w->arg0 = args[0];
    w->arg1 = args[1];
    return Queue(env, w, "ArkClashReload");
}

napi_value Fetch(napi_env env, napi_callback_info info)
{
    std::string args[1];
    if (!GetStringArgs(env, info, 1, args, "fetch(requestJson: string) expects a string")) {
        return nullptr;
    }
    auto *w = new CoreWork();
    w->call = CoreCall::Fetch;
    w->arg0 = args[0];
    return Queue(env, w, "ArkClashFetch");
}

// 实验：attachTun(fd: number, stack: string)
napi_value AttachTun(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t fd = 0;
    std::string stack;
    if (argc < 2 || napi_get_value_int32(env, args[0], &fd) != napi_ok || !GetString(env, args[1], stack)) {
        napi_throw_type_error(env, nullptr, "attachTun(fd: number, stack: string)");
        return nullptr;
    }
    auto *w = new CoreWork();
    w->call = CoreCall::AttachTun;
    w->fd = fd;
    w->arg0 = stack;
    return Queue(env, w, "ArkClashAttachTun");
}

napi_value RunningProfile(napi_env env, napi_callback_info)
{
    std::string profile = TakeString(ArkClashRunningProfile());
    napi_value result;
    napi_create_string_utf8(env, profile.c_str(), profile.size(), &result);
    return result;
}

napi_value Prefetch(napi_env env, napi_callback_info info)
{
    std::string args[1];
    if (!GetStringArgs(env, info, 1, args, "prefetch(path: string) expects a string")) {
        return nullptr;
    }
    auto *w = new CoreWork();
    w->call = CoreCall::Prefetch;
    w->arg0 = args[0];
    return Queue(env, w, "ArkClashPrefetch");
}

napi_value Version(napi_env env, napi_callback_info)
{
    std::string v = TakeString(ArkClashVersion());
    napi_value result;
    napi_create_string_utf8(env, v.c_str(), v.size(), &result);
    return result;
}

// ---- 订阅类命令：Go → ArkTS ----

struct Command {
    long long id;
    std::string name;
    std::string body;
};

napi_threadsafe_function g_commandFn = nullptr;

// 在 ArkTS 线程上调用 onCommand 登记的回调：(id, name, body)。
void CallCommand(napi_env env, napi_value callback, void *, void *data)
{
    auto *c = static_cast<Command *>(data);
    if (env != nullptr && callback != nullptr) {
        napi_value args[3];
        napi_create_int64(env, c->id, &args[0]);
        napi_create_string_utf8(env, c->name.c_str(), c->name.size(), &args[1]);
        napi_create_string_utf8(env, c->body.c_str(), c->body.size(), &args[2]);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_call_function(env, undefined, callback, 3, args, nullptr);
    }
    delete c;
}

// 由 Go 在它自己的线程上调用，name 和 body 在返回后失效，所以先复制。
void OnCommand(long long id, const char *name, const char *body)
{
    auto *c = new Command{id, name, body};
    if (g_commandFn == nullptr || napi_call_threadsafe_function(g_commandFn, c, napi_tsfn_nonblocking) != napi_ok) {
        delete c;
        char msg[] = "{\"message\":\"command handler is not ready\"}";
        ArkClashReply(id, 503, msg);
    }
}

napi_value OnCommandJs(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value callback = nullptr;
    napi_get_cb_info(env, info, &argc, &callback, nullptr, nullptr);
    napi_valuetype type = napi_undefined;
    if (argc < 1 || napi_typeof(env, callback, &type) != napi_ok || type != napi_function) {
        napi_throw_type_error(env, nullptr, "onCommand(callback) expects a function");
        return nullptr;
    }
    ArkClashSetCommandHandler(nullptr);
    if (g_commandFn != nullptr) {
        napi_release_threadsafe_function(g_commandFn, napi_tsfn_release);
        g_commandFn = nullptr;
    }
    napi_value resourceName;
    napi_create_string_utf8(env, "ArkClashCommand", NAPI_AUTO_LENGTH, &resourceName);
    napi_create_threadsafe_function(env, callback, nullptr, resourceName, 0, 1, nullptr, nullptr, nullptr,
                                    CallCommand, &g_commandFn);
    ArkClashSetCommandHandler(OnCommand);
    return nullptr;
}

napi_value Reply(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t id = 0;
    int32_t status = 0;
    std::string body;
    if (argc < 3 || napi_get_value_int64(env, args[0], &id) != napi_ok ||
        napi_get_value_int32(env, args[1], &status) != napi_ok || !GetString(env, args[2], body)) {
        napi_throw_type_error(env, nullptr, "reply(id: number, status: number, body: string)");
        return nullptr;
    }
    ArkClashReply(id, status, body.data());
    return nullptr;
}

napi_value Emit(napi_env env, napi_callback_info info)
{
    std::string args[1];
    if (!GetStringArgs(env, info, 1, args, "emit(eventJson: string) expects a string")) {
        return nullptr;
    }
    ArkClashEmit(args[0].data());
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reload", nullptr, Reload, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"fetch", nullptr, Fetch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"prefetch", nullptr, Prefetch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"attachTun", nullptr, AttachTun, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runningProfile", nullptr, RunningProfile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"onCommand", nullptr, OnCommandJs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reply", nullptr, Reply, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"emit", nullptr, Emit, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module arkclashModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "arkclash",
    .nm_priv = nullptr,
    .reserved = {0},
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterArkClashModule(void)
{
    napi_module_register(&arkclashModule);
}
