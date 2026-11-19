package script

/*
#cgo CFLAGS: -D_GNU_SOURCE -DQUICKJS_NG_BUILD -fvisibility=hidden
#cgo linux LDFLAGS: -lm
#include <stdlib.h>
#include "bridge.h"
*/
import "C"

import (
	"bytes"
	"context"
	"fmt"
	"time"
	"unsafe"
)

const Timeout = 10 * time.Second
const ConfigLimit = 64 << 20
const sourceLimit = 4 << 20

var statusCodes = [...]string{
	"", "", "syntax", "entry", "execution", "rejection", "pending", "return", "size", "timeout", "canceled", "memory", "input", "stack",
}

type Error struct {
	Code         string
	Line, Column int
}

func (err *Error) Error() string {
	if err.Line > 0 {
		return fmt.Sprintf("script_%s:%d:%d", err.Code, err.Line, err.Column)
	}
	return "script_" + err.Code
}

// Evaluate 返回配置 JSON。脚本返回 null 或 undefined 时，保留进入运行时前的配置。
func Evaluate(ctx context.Context, source string, input []byte) ([]byte, error) {
	return evaluate(ctx, source, input, Timeout)
}

func evaluate(ctx context.Context, source string, input []byte, timeout time.Duration) ([]byte, error) {
	if len(source) > sourceLimit || len(input) > ConfigLimit {
		return nil, &Error{Code: "size"}
	}
	cancel := C.script_cancel_new()
	if cancel == nil {
		return nil, &Error{Code: "memory"}
	}
	defer C.free(unsafe.Pointer(cancel))
	canceled := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		C.script_cancel_set(cancel)
		close(canceled)
	})
	defer func() {
		if !stop() {
			<-canceled
		}
	}()
	if ctx.Err() != nil {
		return nil, &Error{Code: "canceled"}
	}
	// QuickJS 要求 eval 和 JSON 缓冲在显式长度后还有一个 NUL。
	code := C.CString(source)
	defer C.free(unsafe.Pointer(code))
	config := append(input[:len(input):len(input)], 0)
	result := C.script_evaluate(code, C.size_t(len(source)), (*C.char)(unsafe.Pointer(&config[0])),
		C.size_t(len(input)), cancel, C.int(timeout.Milliseconds()))
	defer C.free(unsafe.Pointer(result.data))
	switch result.status {
	case 0:
		decoded := bytes.TrimSpace(C.GoBytes(unsafe.Pointer(result.data), C.int(result.size)))
		if len(decoded) == 0 || decoded[0] != '{' {
			return nil, &Error{Code: "return"}
		}
		return decoded, nil
	case 1:
		return input, nil
	default:
		return nil, &Error{Code: statusCodes[result.status], Line: int(result.line), Column: int(result.column)}
	}
}
