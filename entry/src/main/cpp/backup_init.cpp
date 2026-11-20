#include <dlfcn.h>
#include <hilog/log.h>
#include <napi/native_api.h>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {
using Run = char *(*)(const char *);
using Free = void (*)(char *);

struct BackupWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string request;
    std::string response = R"({"error":"backup_io"})";
};

void RunBackup(napi_env, void *data)
{
    auto &job = *static_cast<BackupWork *>(data);
    // 首次使用备份才加载独立存储库，界面冷启动不初始化它的 Go 运行时。
    static std::once_flag load;
    static Run run = nullptr;
    static Free release = nullptr;
    std::call_once(load, [] {
        void *library = dlopen("libarkstore_impl.so", RTLD_NOW | RTLD_LOCAL);
        if (library != nullptr) {
            run = reinterpret_cast<Run>(dlsym(library, "ArkStoreRun"));
            release = reinterpret_cast<Free>(dlsym(library, "ArkStoreFree"));
        } else {
            OH_LOG_Print(LOG_APP, LOG_ERROR, 0xD000, "ArkClashBackup", "存储库装载失败 %{public}s", dlerror());
        }
    });
    if (run == nullptr || release == nullptr) {
        job.response = R"({"error":"backup_native_unavailable"})";
    } else {
        char *result = run(job.request.c_str());
        if (result != nullptr) {
            job.response = result;
            release(result);
        }
    }
}

void FinishBackup(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<BackupWork> job(static_cast<BackupWork *>(data));
    napi_value result;
    if (status == napi_ok && napi_create_string_utf8(env, job->response.data(), job->response.size(), &result) == napi_ok) {
        napi_resolve_deferred(env, job->deferred, result);
    } else {
        napi_get_undefined(env, &result);
        napi_reject_deferred(env, job->deferred, result);
    }
    napi_delete_async_work(env, job->work);
}

napi_value BackupRun(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value arg;
    size_t size = 0;
    if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1 ||
        napi_get_value_string_utf8(env, arg, nullptr, 0, &size) != napi_ok || size > 32 * 1024) {
        napi_throw_type_error(env, nullptr, "backup_io");
        return nullptr;
    }
    std::vector<char> bytes(size + 1);
    if (napi_get_value_string_utf8(env, arg, bytes.data(), bytes.size(), &size) != napi_ok) {
        napi_throw_type_error(env, nullptr, "backup_io");
        return nullptr;
    }
    auto job = std::make_unique<BackupWork>();
    job->request.assign(bytes.data(), size);
    napi_value promise;
    napi_value name;
    if (napi_create_promise(env, &job->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "ArkClashBackup", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_async_work(env, nullptr, name, RunBackup, FinishBackup, job.get(), &job->work) != napi_ok) {
        napi_throw_error(env, nullptr, "backup_io");
        return nullptr;
    }
    if (napi_queue_async_work(env, job->work) != napi_ok) {
        napi_delete_async_work(env, job->work);
        napi_throw_error(env, nullptr, "backup_io");
        return nullptr;
    }
    (void)job.release();
    return promise;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor functions[] = {
        {"run", nullptr, BackupRun, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, 1, functions);
    return exports;
}

napi_module module = {1, 0, nullptr, Init, "arkstore", nullptr, {0}};
}
extern "C" __attribute__((constructor)) void RegisterArkStore()
{
    napi_module_register(&module);
}
