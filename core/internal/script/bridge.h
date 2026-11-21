#ifndef ARKCLASH_SCRIPT_BRIDGE_H
#define ARKCLASH_SCRIPT_BRIDGE_H
#include <stddef.h>

typedef struct ScriptCancel ScriptCancel;
typedef struct {
    char *data;
    size_t size;
    int line;
    int column;
    int status;
} ScriptResult;

ScriptCancel *script_cancel_new(void);
void script_cancel_set(ScriptCancel *cancel);
ScriptResult script_evaluate(const char *source, size_t source_len, const char *input, size_t input_len,
                             ScriptCancel *cancel, int timeout_ms);
#endif
