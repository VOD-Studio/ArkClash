#include "bridge.h"
#include <quickjs.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SCRIPT_FILE "arkclash-script.js"
#define MEMORY_LIMIT (256u << 20)
#define OUTPUT_LIMIT (64u << 20)

enum { OK, ORIGINAL, COMPILE, ENTRY, EXECUTE, REJECT, PENDING, RETURN, SIZE, TIMEOUT, CANCELED, MEMORY, INPUT, STACK };

struct ScriptCancel { atomic_bool canceled; };

typedef struct {
    ScriptCancel *cancel;
    int64_t end;
    int stopped;
} ScriptBudget;

ScriptCancel *script_cancel_new(void) {
    ScriptCancel *cancel = malloc(sizeof(*cancel));
    if (cancel) atomic_init(&cancel->canceled, false);
    return cancel;
}

void script_cancel_set(ScriptCancel *cancel) {
    atomic_store_explicit(&cancel->canceled, true, memory_order_relaxed);
}

static int64_t now_ms(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (int64_t)time.tv_sec * 1000 + time.tv_nsec / 1000000;
}

static int interrupt(JSRuntime *rt, void *opaque) {
    (void)rt;
    ScriptBudget *budget = opaque;
    if (atomic_load_explicit(&budget->cancel->canceled, memory_order_relaxed)) budget->stopped = CANCELED;
    else if (now_ms() >= budget->end) budget->stopped = TIMEOUT;
    return budget->stopped != 0;
}

static JSValue console_sink(JSContext *ctx, JSValueConst self, int argc, JSValueConst *argv) {
    (void)ctx; (void)self; (void)argc; (void)argv;
    return JS_UNDEFINED;
}

static int install_console(JSContext *ctx) {
    static const char *methods[] = { "log", "info", "warn", "error", "debug", "trace" };
    JSValue console = JS_NewObject(ctx);
    if (JS_IsException(console)) return -1;
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        if (JS_SetPropertyStr(ctx, console, methods[i], JS_NewCFunction(ctx, console_sink, methods[i], 0)) < 0) {
            JS_FreeValue(ctx, console);
            return -1;
        }
    }
    JSValue global = JS_GetGlobalObject(ctx);
    const int rc = JS_SetPropertyStr(ctx, global, "console", console);
    JS_FreeValue(ctx, global);
    return rc;
}

static long script_position(const char *digits, char **end) {
    if (*digits < '0' || *digits > '9') return 0;
    long number = strtol(digits, end, 10);
    return number > 0 && number < 10000000 ? number : 0;
}

static void describe_error(JSContext *ctx, JSValueConst error, ScriptResult *result) {
    if (!JS_IsError(error)) return;
    // 仅从自有数据属性提取位置。异常文本可能包含完整配置，且读取 getter 可能再次运行脚本。
    for (int i = 0; i < 2; i++) {
        JSAtom atom = JS_NewAtom(ctx, i == 0 ? "message" : "stack");
        JSPropertyDescriptor desc;
        int found = JS_GetOwnProperty(ctx, &desc, error, atom);
        JS_FreeAtom(ctx, atom);
        if (found <= 0) continue;
        const char *text = JS_IsString(desc.value) ? JS_ToCString(ctx, desc.value) : NULL;
        if (text && i == 0) {
            if (strcmp(text, "out of memory") == 0) result->status = MEMORY;
            if (strcmp(text, "Maximum call stack size exceeded") == 0) result->status = STACK;
        } else if (text) {
            const char *location = strstr(text, SCRIPT_FILE ":");
            if (location) {
                char *end = NULL;
                result->line = (int)script_position(location + sizeof(SCRIPT_FILE), &end);
                if (end && *end == ':') result->column = (int)script_position(end + 1, &end);
            }
        }
        if (text) JS_FreeCString(ctx, text);
        JS_FreeValue(ctx, desc.value);
        JS_FreeValue(ctx, desc.getter);
        JS_FreeValue(ctx, desc.setter);
    }
}

ScriptResult script_evaluate(const char *source, size_t source_len, const char *input, size_t input_len,
                             ScriptCancel *cancel, int timeout_ms) {
    ScriptResult out = { .status = MEMORY };
    ScriptBudget budget = { .cancel = cancel, .end = now_ms() + timeout_ms };
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return out;
    JS_SetMemoryLimit(rt, MEMORY_LIMIT);
    JS_SetMaxStackSize(rt, 512u << 10);
    JS_SetInterruptHandler(rt, interrupt, &budget);
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) { JS_FreeRuntime(rt); return out; }

    JSValue entry = JS_UNDEFINED, config = JS_UNDEFINED, result = JS_UNDEFINED, json = JS_UNDEFINED;
    if (interrupt(rt, &budget) || install_console(ctx) < 0) goto done;
    out.status = COMPILE;
    JSValue compiled = JS_Eval(ctx, source, source_len, SCRIPT_FILE, JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    if (JS_IsException(compiled)) goto exception;
    out.status = EXECUTE;
    JSValue initialized = JS_EvalFunction(ctx, compiled);
    if (JS_IsException(initialized)) goto exception;
    JS_FreeValue(ctx, initialized);
    out.status = ENTRY;
    entry = JS_Eval(ctx, "main", 4, "<entry>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(entry)) goto exception;
    if (!JS_IsFunction(ctx, entry)) goto done;
    out.status = INPUT;
    config = JS_ParseJSON(ctx, input, input_len, "<config>");
    if (JS_IsException(config)) goto exception;
    out.status = EXECUTE;
    result = JS_Call(ctx, entry, JS_UNDEFINED, 1, &config);
    if (JS_IsException(result)) goto exception;
    JSPromiseStateEnum state = JS_PromiseState(ctx, result);
    if (state != JS_PROMISE_NOT_A_PROMISE) {
        while (state == JS_PROMISE_PENDING) {
            if (interrupt(rt, &budget)) goto done;
            JSContext *job_ctx = NULL;
            int ran = JS_ExecutePendingJob(rt, &job_ctx);
            if (ran < 0) { out.status = REJECT; goto exception; }
            if (ran == 0) { out.status = PENDING; goto done; }
            state = JS_PromiseState(ctx, result);
        }
        JSValue settled = JS_PromiseResult(ctx, result);
        JS_FreeValue(ctx, result);
        result = settled;
        if (state == JS_PROMISE_REJECTED) {
            out.status = REJECT;
            describe_error(ctx, result, &out);
            goto done;
        }
    }
    if (JS_IsNull(result) || JS_IsUndefined(result)) { out.status = ORIGINAL; goto done; }
    out.status = RETURN;
    if (!JS_IsObject(result) || JS_IsArray(result) || JS_IsFunction(ctx, result)) goto done;
    json = JS_JSONStringify(ctx, result, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) goto exception;
    if (!JS_IsString(json)) goto done;
    size_t length = 0;
    const char *encoded = JS_ToCStringLen(ctx, &length, json);
    if (!encoded) goto exception;
    if (length > OUTPUT_LIMIT) out.status = SIZE;
    else if ((out.data = malloc(length)) == NULL) out.status = MEMORY;
    else { memcpy(out.data, encoded, length); out.size = length; out.status = OK; }
    JS_FreeCString(ctx, encoded);
    goto done;

exception: {
    JSValue error = JS_GetException(ctx);
    if (!budget.stopped) describe_error(ctx, error, &out);
    JS_FreeValue(ctx, error);
}
done:
    if (interrupt(rt, &budget)) out.status = budget.stopped;
    JS_FreeValue(ctx, json);
    JS_FreeValue(ctx, result);
    JS_FreeValue(ctx, config);
    JS_FreeValue(ctx, entry);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return out;
}
