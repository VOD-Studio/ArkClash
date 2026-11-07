package main

/*
#cgo LDFLAGS: -lnet_connection
#include <network/netmanager/net_connection.h>

static int32_t arkclash_bind_socket(int32_t fd) {
	NetConn_NetHandle handle = {0};
	int32_t result = OH_NetConn_GetDefaultNet(&handle);
	if (result != 0) {
		return result;
	}
	return OH_NetConn_BindSocket(fd, &handle);
}
*/
import "C"

import (
	"fmt"
	"syscall"

	"github.com/metacubex/mihomo/component/dialer"
)

func init() {
	// Go 绕过 libc 的进程保护；在 connect/send 前逐个绑定默认物理网络，避免出站重新进入 TUN。
	dialer.DefaultSocketHook = protectSocket
}

func protectSocket(_, _ string, raw syscall.RawConn) error {
	var result C.int32_t
	if err := raw.Control(func(fd uintptr) {
		result = C.arkclash_bind_socket(C.int32_t(fd))
	}); err != nil {
		return err
	}
	if result != 0 {
		return fmt.Errorf("protect outbound socket: %d", int32(result))
	}
	return nil
}
