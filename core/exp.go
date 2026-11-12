// 阶段 0 真机实验用的代码，只存在于实验分支，不合并。
package main

/*
#include <stdlib.h>
#include <hilog/log.h>

static void arkclash_exp_log(const char *msg) {
	OH_LOG_Print(LOG_APP, LOG_INFO, 0x0A11, "ArkClashExp", "%{public}s", msg);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"
	"unsafe"
)

// expLog 打一条带毫秒时间戳的实验日志，和 ArkTS 侧的格式一致，方便按时间对齐两个进程。
func expLog(format string, args ...any) {
	msg := C.CString(fmt.Sprintf("EXP t=%d side=go pid=%d ", time.Now().UnixMilli(), os.Getpid()) +
		fmt.Sprintf(format, args...))
	C.arkclash_exp_log(msg)
	C.free(unsafe.Pointer(msg))
}

var expListener net.Listener

// startExpSocket 在应用沙箱里监听一个 Unix 套接字，验证界面进程能不能连上（实验四）。
func startExpSocket(homeDir string) {
	path := filepath.Join(homeDir, "exp.sock")
	_ = os.Remove(path)
	l, err := net.Listen("unix", path)
	if err != nil {
		expLog("event=sock-listen ok=false err=%q", err.Error())
		return
	}
	expListener = l
	expLog("event=sock-listen ok=true path=%s", path)
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 64)
				_ = c.SetDeadline(time.Now().Add(3 * time.Second))
				n, _ := c.Read(buf)
				expLog("event=sock-accept got=%q", string(buf[:n]))
				_, _ = c.Write([]byte(fmt.Sprintf("pong pid=%d\n", os.Getpid())))
			}(conn)
		}
	}()
}

func stopExpSocket() {
	if expListener != nil {
		_ = expListener.Close()
		expListener = nil
	}
}

// attachTun 给待机中的内核接上隧道（实验三的热路径）。
func attachTun(fd int, stack string) error {
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return errors.New("core is not running")
	}
	if tunListener != nil {
		return errors.New("tun is already attached")
	}
	if fd <= 0 {
		return errors.New("invalid tun fd")
	}
	t0 := time.Now()
	if err := startTun(fd, stack); err != nil {
		return err
	}
	expLog("event=attach-tun ms=%d", time.Since(t0).Milliseconds())
	return nil
}

// ArkClashAttachTun 给待机中的内核接上隧道。成功返回 NULL，否则返回错误信息，用 ArkClashFree 释放。
//
//export ArkClashAttachTun
func ArkClashAttachTun(fd C.int, stack *C.char) *C.char {
	return errorString(attachTun(int(fd), C.GoString(stack)))
}
