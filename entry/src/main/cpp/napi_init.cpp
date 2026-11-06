// NAPI bridge between ArkTS and libclash.so. start/stop run on the libuv
// worker pool so the ArkTS thread never blocks on the core.
#include <string>

#include "arkclash.h"
#include "napi/native_api.h"

namespace {

struct CoreWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    bool isStart = false;
    std::string options;
    std::string error;
};

void Execute(napi_env, void *data)
{
    auto *w = static_cast<CoreWork *>(data);
    if (!w->isStart) {
        ArkClashStop();
        return;
    }
    char *err = ArkClashStart(w->options.data());
    if (err != nullptr) {
        w->error = err;
        ArkClashFree(err);
    }
}

void Complete(napi_env env, napi_status, void *data)
{
    auto *w = static_cast<CoreWork *>(data);
    if (w->error.empty()) {
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        napi_resolve_deferred(env, w->deferred, undefined);
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

napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    size_t len = 0;
    if (argc < 1 || napi_get_value_string_utf8(env, args[0], nullptr, 0, &len) != napi_ok) {
        napi_throw_type_error(env, nullptr, "start(optionsJson: string) expects a string");
        return nullptr;
    }
    auto *w = new CoreWork();
    w->isStart = true;
    w->options.resize(len);
    napi_get_value_string_utf8(env, args[0], w->options.data(), len + 1, &len);
    return Queue(env, w, "ArkClashStart");
}

napi_value Stop(napi_env env, napi_callback_info)
{
    return Queue(env, new CoreWork(), "ArkClashStop");
}

napi_value Version(napi_env env, napi_callback_info)
{
    char *v = ArkClashVersion();
    napi_value result;
    napi_create_string_utf8(env, v, NAPI_AUTO_LENGTH, &result);
    ArkClashFree(v);
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
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
