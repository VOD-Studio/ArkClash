package main

/*
#cgo LDFLAGS: -lnet_connection
#include <net/if.h>
#include <network/netmanager/net_connection.h>

extern void arkClashTailscaleNetworkChanged(void);

static void arkclash_ts_changed(NetConn_NetHandle *handle) {
	(void) handle;
	arkClashTailscaleNetworkChanged();
}

static void arkclash_ts_properties(NetConn_NetHandle *handle, NetConn_ConnectionProperties *properties) {
	(void) properties;
	arkclash_ts_changed(handle);
}

static int32_t arkclash_ts_subscribe(uint32_t *id) {
	static NetConn_NetConnCallback callbacks = {
		.onNetworkAvailable = arkclash_ts_changed,
		.onConnetionProperties = arkclash_ts_properties,
		.onNetLost = arkclash_ts_changed,
		.onNetUnavailable = arkClashTailscaleNetworkChanged,
	};
	return OH_NetConn_RegisterDefaultNetConnCallback(&callbacks, id);
}
*/
import "C"

import (
	"fmt"
	"net"
	"net/netip"

	"github.com/metacubex/tailscale/net/netmon"
)

func init() {
	netmon.SetArkClashNetwork(tailscaleInterfaces, func(notify func()) (func() error, error) {
		return tailnetWatches.subscribe(notify, registerTailscaleNetwork, unregisterTailscaleNetwork)
	})
}

var tailnetWatches tailscaleNetworkWatches

//export arkClashTailscaleNetworkChanged
func arkClashTailscaleNetworkChanged() {
	// Network Kit 回调只投递可合并的信号，网卡快照由 netmon 的协程读取。
	tailnetWatches.changed()
}

func registerTailscaleNetwork() (uint32, error) {
	var id C.uint32_t
	if code := C.arkclash_ts_subscribe(&id); code != 0 {
		return 0, fmt.Errorf("subscribe to default network: %d", code)
	}
	return uint32(id), nil
}

func unregisterTailscaleNetwork(id uint32) error {
	const callbackNotFound = 2101007
	if code := C.OH_NetConn_UnregisterNetConnCallback(C.uint32_t(id)); code != 0 && code != callbackNotFound {
		return fmt.Errorf("unsubscribe from default network: %d", code)
	}
	return nil
}

func tailscaleInterfaces() ([]netmon.Interface, error) {
	var handle C.NetConn_NetHandle
	var properties C.NetConn_ConnectionProperties
	code := C.OH_NetConn_GetDefaultNet(&handle)
	if code == 0 {
		code = C.OH_NetConn_GetConnectionProperties(&handle, &properties)
	}
	if code != 0 {
		// 离线时允许 tsnet 启动；后续连网事件会更新初始空快照。
		var available C.int32_t
		if C.OH_NetConn_HasDefaultNet(&available) == 0 && available == 0 {
			return nil, nil
		}
		return nil, fmt.Errorf("read default network interface: %d", code)
	}
	properties.ifaceName[len(properties.ifaceName)-1] = 0
	name := C.GoString(&properties.ifaceName[0])
	if name == "" {
		return nil, nil
	}
	count := max(0, min(int(properties.netAddrListSize), len(properties.netAddrList)))
	addrs := make([]net.Addr, 0, count)
	for i := range count {
		entry := &properties.netAddrList[i]
		entry.address[len(entry.address)-1] = 0
		ip, err := netip.ParseAddr(C.GoString(&entry.address[0]))
		if err == nil {
			ip = ip.WithZone("")
			if prefix := netip.PrefixFrom(ip, int(entry.prefixlen)); prefix.IsValid() {
				addrs = append(addrs, &net.IPNet{IP: net.IP(ip.AsSlice()), Mask: net.CIDRMask(prefix.Bits(), ip.BitLen())})
			}
		}
	}
	return []netmon.Interface{{
		Interface: &net.Interface{Name: name, Index: int(C.if_nametoindex(&properties.ifaceName[0])),
			MTU: int(properties.mtu), Flags: net.FlagUp | net.FlagRunning},
		AltAddrs: addrs,
	}}, nil
}
