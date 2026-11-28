#define _POSIX_C_SOURCE 200809L
#include "arkclash.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { OLD_THREADS = 4, NEW_THREADS = 4, NEW_WAVES = 4, ITERATIONS = 250 };

static struct {
    __typeof__(&ArkClashVersion) version;
    __typeof__(&ArkClashRunningProfile) profile;
    __typeof__(&ArkClashStart) start;
    __typeof__(&ArkClashFree) release;
} api;

static pthread_mutex_t gate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cond = PTHREAD_COND_INITIALIZER;
static unsigned ready_threads;
static int released;
static const char *expected_version;

struct worker {
    unsigned id;
    unsigned iterations;
};

static void fail(const char *message)
{
    fprintf(stderr, "core-smoke: FAIL %s\n", message);
    exit(EXIT_FAILURE);
}

static void check_thread(int error, const char *operation)
{
    if (error != 0) {
        fprintf(stderr, "core-smoke: FAIL %s: %s\n", operation, strerror(error));
        exit(EXIT_FAILURE);
    }
}

static void check_string(char *actual, const char *expected, const char *operation,
                         unsigned worker, unsigned iteration)
{
    int matches = actual != NULL && strcmp(actual, expected) == 0;
    if (actual != NULL) {
        api.release(actual);
    }
    if (!matches) {
        fprintf(stderr, "core-smoke: FAIL %s mismatch (worker=%u iteration=%u)\n",
                operation, worker, iteration);
        exit(EXIT_FAILURE);
    }
}

static void exercise(struct worker *worker)
{
    for (unsigned i = 0; i < ITERATIONS; ++i) {
        char invalid_json[] = "{";
        check_string(api.version(), expected_version, "version", worker->id, i);
        check_string(api.profile(), "", "stopped profile", worker->id, i);
        char *error = api.start(invalid_json);
        if (error == NULL || error[0] == '\0') {
            if (error != NULL) {
                api.release(error);
            }
            fail("invalid JSON was not rejected");
        }
        api.release(error);
        check_string(api.profile(), "", "profile after rejection", worker->id, i);
        ++worker->iterations;
    }
}

static void *run_worker(void *argument)
{
    check_thread(pthread_mutex_lock(&gate_mutex), "lock worker gate");
    ++ready_threads;
    check_thread(pthread_cond_broadcast(&gate_cond), "announce worker ready");
    while (!released) {
        check_thread(pthread_cond_wait(&gate_cond, &gate_mutex), "wait for dlopen");
    }
    check_thread(pthread_mutex_unlock(&gate_mutex), "unlock worker gate");
    exercise(argument);
    return NULL;
}

static void *resolve(void *library, const char *name)
{
    dlerror();
    void *symbol = dlsym(library, name);
    const char *error = dlerror();
    if (error != NULL || symbol == NULL) {
        fprintf(stderr, "core-smoke: FAIL dlsym %s: %s\n", name,
                error != NULL ? error : "null symbol");
        exit(EXIT_FAILURE);
    }
    return symbol;
}

static double monotonic_seconds(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        fail("clock_gettime");
    }
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fail("usage: core-smoke /path/to/libclash.so");
    }
    // 宿主 hdc 断开也不能留下挂住的测试进程；宿主另有 timeout 兜底。
    alarm(45);
    const double started = monotonic_seconds();
    pthread_t old_threads[OLD_THREADS];
    pthread_t new_threads[NEW_THREADS];
    struct worker old_workers[OLD_THREADS] = {0};
    struct worker new_workers[NEW_THREADS] = {0};
    struct worker main_worker = { .id = 0, .iterations = 0 };

    for (unsigned i = 0; i < OLD_THREADS; ++i) {
        old_workers[i].id = i + 1;
        check_thread(pthread_create(&old_threads[i], NULL, run_worker, &old_workers[i]),
                     "create pre-dlopen thread");
    }
    // 确认线程已经进入等待，避免把尚未启动的线程误算成 dlopen 前线程。
    check_thread(pthread_mutex_lock(&gate_mutex), "lock ready gate");
    while (ready_threads != OLD_THREADS) {
        check_thread(pthread_cond_wait(&gate_cond, &gate_mutex), "wait for old threads");
    }
    check_thread(pthread_mutex_unlock(&gate_mutex), "unlock ready gate");

    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        fprintf(stderr, "core-smoke: FAIL dlopen: %s\n", dlerror());
        return EXIT_FAILURE;
    }
    api.version = (__typeof__(api.version))resolve(library, "ArkClashVersion");
    api.profile = (__typeof__(api.profile))resolve(library, "ArkClashRunningProfile");
    api.start = (__typeof__(api.start))resolve(library, "ArkClashStart");
    api.release = (__typeof__(api.release))resolve(library, "ArkClashFree");
    char *version = api.version();
    if (version == NULL || version[0] == '\0') {
        if (version != NULL) {
            api.release(version);
        }
        fail("empty version");
    }
    expected_version = version;
    unsigned completed = 0;

    for (unsigned wave = 0; wave < NEW_WAVES; ++wave) {
        for (unsigned i = 0; i < NEW_THREADS; ++i) {
            new_workers[i].id = OLD_THREADS + wave * NEW_THREADS + i + 1;
            new_workers[i].iterations = 0;
            check_thread(pthread_create(&new_threads[i], NULL, run_worker, &new_workers[i]),
                         "create post-dlopen thread");
        }
        if (wave == 0) {
            check_thread(pthread_mutex_lock(&gate_mutex), "lock release gate");
            released = 1;
            check_thread(pthread_cond_broadcast(&gate_cond), "release workers");
            check_thread(pthread_mutex_unlock(&gate_mutex), "unlock release gate");
            exercise(&main_worker);
            completed += main_worker.iterations;
            for (unsigned i = 0; i < OLD_THREADS; ++i) {
                check_thread(pthread_join(old_threads[i], NULL), "join pre-dlopen thread");
                if (old_workers[i].iterations != ITERATIONS) {
                    fail("incomplete pre-dlopen worker");
                }
                completed += old_workers[i].iterations;
            }
        }
        for (unsigned i = 0; i < NEW_THREADS; ++i) {
            check_thread(pthread_join(new_threads[i], NULL), "join post-dlopen thread");
            if (new_workers[i].iterations != ITERATIONS) {
                fail("incomplete post-dlopen worker");
            }
            completed += new_workers[i].iterations;
        }
    }
    if (completed != (1 + OLD_THREADS + NEW_THREADS * NEW_WAVES) * ITERATIONS) {
        fail("incomplete iteration count");
    }
    api.release(version);
    const double elapsed = monotonic_seconds() - started;
    // Go runtime 不支持 dlclose；让进程退出统一回收共享库和运行时线程。
    printf("core-smoke: PASS pre_threads=%u post_threads=%u iterations=%u "
           "api_calls=%u elapsed_ms=%.3f\n", OLD_THREADS, NEW_THREADS * NEW_WAVES,
           completed, completed * 8 + 2, elapsed * 1000.0);
    return EXIT_SUCCESS;
}
