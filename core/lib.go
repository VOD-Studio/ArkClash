//go:build ohos

// Package main builds libclash.so, the mihomo core loaded by ArkClash's
// VpnExtensionAbility. The exported C API is declared in arkclash.h; keep the
// two in sync.
package main

/*
#include <stdlib.h>

// 必须和 arkclash.h 里的声明一致。
typedef void (*ArkClashCommandHandler)(long long id, const char *name, const char *body);

static void arkclashCallCommandHandler(ArkClashCommandHandler h, long long id, const char *name, const char *body) {
	h(id, name, body);
}
*/
import "C"

import (
	"encoding/json"
	"runtime/debug"
	"sync"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/constant"
)

func errorString(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

// ArkClashStart starts the core. It returns NULL on success or an error
// message that the caller must release with ArkClashFree.
//
//export ArkClashStart
func ArkClashStart(optionsJSON *C.char) *C.char {
	var opts startOptions
	if err := json.Unmarshal([]byte(C.GoString(optionsJSON)), &opts); err != nil {
		return errorString(err)
	}
	return errorString(start(opts))
}

//export ArkClashStop
func ArkClashStop() *C.char {
	return errorString(stop())
}

var reclaimMu sync.Mutex
var lastReclaim time.Time

//export ArkClashReclaimMemory
func ArkClashReclaimMemory() C.int {
	// 一轮压力可能连续产生多次通知；回收期间和刚收完的通知均无需再做全堆 GC。
	if !reclaimMu.TryLock() {
		return 0
	}
	defer reclaimMu.Unlock()
	if time.Since(lastReclaim) < 10*time.Second {
		return 0
	}
	debug.FreeOSMemory()
	lastReclaim = time.Now()
	return 1
}

//export ArkClashAttachTun
func ArkClashAttachTun(fd C.int, optionsJSON, bootID, profile *C.char, configRevision C.ulonglong) *C.char {
	var network tunNetworkOptions
	if err := json.Unmarshal([]byte(C.GoString(optionsJSON)), &network); err != nil {
		return errorString(err)
	}
	return errorString(attachTun(int(fd), network, attachIdentity{
		BootID: C.GoString(bootID), Profile: C.GoString(profile), ConfigRevision: uint64(configRevision),
	}))
}

//export ArkClashDetachTun
func ArkClashDetachTun() *C.char {
	return errorString(detachTun())
}

//export ArkClashUpdateVpnState
func ArkClashUpdateVpnState(intent, forward *C.char, vpnCreated C.int) *C.char {
	mu.Lock()
	defer mu.Unlock()
	return errorString(updateVpnState(C.GoString(intent), C.GoString(forward), vpnCreated != 0))
}

//export ArkClashRuntimeStatus
func ArkClashRuntimeStatus() *C.char {
	data, _ := json.Marshal(runtimeSnapshot.Load())
	return C.CString(string(data))
}

// ArkClashReload 热切换到 path 指向的配置，profile 是它的编号。成功返回 NULL，
// 否则返回错误信息，调用方用 ArkClashFree 释放。
//
//export ArkClashReload
func ArkClashReload(path, profile, expectedProfile *C.char) *C.char {
	var expected *string
	if expectedProfile != nil {
		expected = new(C.GoString(expectedProfile))
	}
	return errorString(reload(C.GoString(path), C.GoString(profile), expected))
}

// ArkClashPrefetch 预先下载 path 里还没下载过的 rule-provider（见 prefetch）。返回 JSON
// {"downloaded":n} 或 {"error":"..."}，用 ArkClashFree 释放。会阻塞到下载结束，只能在工作线程上调用。
//
//export ArkClashPrefetch
func ArkClashPrefetch(path *C.char) *C.char {
	n, err := prefetch(C.GoString(path))
	result := prefetchResult{Downloaded: n}
	if err != nil {
		result.Error = err.Error()
	}
	data, _ := json.Marshal(result)
	return C.CString(string(data))
}

// ArkClashFetch 经内核下载，参数和结果都是 JSON（见 fetchRequest、fetchResult）。
// 返回值由调用方用 ArkClashFree 释放。会阻塞到请求结束，只能在工作线程上调用。
//
//export ArkClashFetch
func ArkClashFetch(requestJSON *C.char) *C.char {
	var req fetchRequest
	result := fetchResult{}
	if err := json.Unmarshal([]byte(C.GoString(requestJSON)), &req); err != nil {
		result.Error = err.Error()
	} else {
		result = fetch(req)
	}
	data, _ := json.Marshal(result)
	return C.CString(string(data))
}

// ArkClashSetCommandHandler 登记处理订阅类命令的回调。回调在 Go 的线程上调用，name 和 body
// 只在回调期间有效；处理完后用 ArkClashReply 回复同一个 id。
//
//export ArkClashSetCommandHandler
func ArkClashSetCommandHandler(handler C.ArkClashCommandHandler) {
	if handler == nil {
		setCommandDispatcher(nil)
		return
	}
	setCommandDispatcher(func(id int64, name, body string) {
		cName := C.CString(name)
		cBody := C.CString(body)
		C.arkclashCallCommandHandler(handler, C.longlong(id), cName, cBody)
		C.free(unsafe.Pointer(cName))
		C.free(unsafe.Pointer(cBody))
	})
}

// ArkClashReply 回复一条命令；请求已超时或断开时直接丢弃。body 由调用方保留所有权。
//
//export ArkClashReply
func ArkClashReply(id C.longlong, status C.int, body *C.char) {
	replyCommand(int64(id), int(status), []byte(C.GoString(body)))
}

// ArkClashEmit 由 VPN 进程的 ArkTS 推送一条事件（JSON 对象），body 由调用方保留所有权。
//
//export ArkClashEmit
func ArkClashEmit(event *C.char) {
	emitRaw([]byte(C.GoString(event)))
}

// ArkClashRunningProfile 返回正在运行的配置编号，没在运行时是空串。用 ArkClashFree 释放。
//
//export ArkClashRunningProfile
func ArkClashRunningProfile() *C.char {
	profile, _ := runningProfile()
	return C.CString(profile)
}

// ArkClashVersion returns the mihomo version. Release it with ArkClashFree.
//
//export ArkClashVersion
func ArkClashVersion() *C.char {
	return C.CString(constant.Version)
}

//export ArkClashFree
func ArkClashFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
