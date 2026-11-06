package main

/*
#cgo LDFLAGS: -lhilog_ndk.z
#include <stdlib.h>
#include <hilog/log.h>

// OH_LOG_Print is variadic, which cgo cannot call directly.
static void arkclash_log(int level, const char *msg) {
	OH_LOG_Print(LOG_APP, (LogLevel)level, 0x0A11, "ArkClashCore", "%{public}s", msg);
}
*/
import "C"

import (
	"unsafe"

	"github.com/metacubex/mihomo/log"
)

// Forward mihomo logs to hilog; stdout goes nowhere inside an app process.
func init() {
	sub := log.Subscribe()
	go func() {
		for event := range sub {
			msg := C.CString(event.Payload)
			C.arkclash_log(hilogLevel(event.LogLevel), msg)
			C.free(unsafe.Pointer(msg))
		}
	}()
}

func hilogLevel(level log.LogLevel) C.int {
	switch level {
	case log.DEBUG:
		return C.LOG_DEBUG
	case log.WARNING:
		return C.LOG_WARN
	case log.ERROR:
		return C.LOG_ERROR
	default:
		return C.LOG_INFO
	}
}
