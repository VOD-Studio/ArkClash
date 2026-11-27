//go:build ohos

package platform

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
	"sync"
	"unsafe"

	"github.com/metacubex/mihomo/log"
)

var hilogOnce sync.Once

// StartHilog 订阅 mihomo 日志并经由入口注入的脱敏格式化函数转发到 hilog；
// 仅转发已知模板，避免把未脱敏载荷写入系统日志。
func StartHilog(format func(log.Event) string) {
	if format == nil {
		return
	}
	hilogOnce.Do(func() {
		sub := log.Subscribe()
		go func() {
			for event := range sub {
				var message string
				switch event.Template {
				case "[ArkClash] core started", "[ArkClash] reloaded profile %s",
					"[ArkClash] core stopped with pending VPN resources: %s",
					"[ArkClash] external controller port unavailable":
					message = format(event)
				case "[%s] %s --> %s using DIRECT", "[%s] %s --> %s using GLOBAL",
					"[%s] %s --> %s using %s", "[%s] %s --> %s match %s using %s",
					"[%s] %s --> %s doesn't match any rule using %s":
					if log.Level() > log.INFO {
						continue
					}
					message = format(event)
				default:
					continue
				}
				msg := C.CString(message)
				C.arkclash_log(hilogLevel(event.LogLevel), msg)
				C.free(unsafe.Pointer(msg))
			}
		}()
	})
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
