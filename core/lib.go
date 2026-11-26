// Package main builds libclash.so, the mihomo core loaded by ArkClash's
// VpnExtensionAbility. The exported C API is declared in arkclash.h; keep the
// two in sync.
package main

/*
#include <stdlib.h>
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
