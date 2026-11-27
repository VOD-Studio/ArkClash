//go:build ohos

package main

/*
#cgo LDFLAGS: -lnet_connection
#include <net/if.h>
#include <network/netmanager/net_connection.h>
#include <stdatomic.h>
#include <string.h>

static atomic_uint_fast64_t arkclash_dns_generation;

static void arkclash_dns_network_changed(NetConn_NetHandle *handle) {
    (void) handle;
    atomic_fetch_add_explicit(&arkclash_dns_generation, 1, memory_order_relaxed);
}

static void arkclash_dns_properties_changed(NetConn_NetHandle *handle, NetConn_ConnectionProperties *properties) {
    (void) properties;
    arkclash_dns_network_changed(handle);
}

static void arkclash_dns_capabilities_changed(NetConn_NetHandle *handle, NetConn_NetCapabilities *capabilities) {
    (void) handle;
    (void) capabilities;
}

static void arkclash_dns_network_unavailable(void) {
    arkclash_dns_network_changed(NULL);
}

static void arkclash_dns_block_changed(NetConn_NetHandle *handle, bool blocked) {
    (void) handle;
    (void) blocked;
}

static int32_t arkclash_watch_dns_network(void) {
    static NetConn_NetConnCallback callbacks = {
        .onNetworkAvailable = arkclash_dns_network_changed,
        .onNetCapabilitiesChange = arkclash_dns_capabilities_changed,
        .onConnetionProperties = arkclash_dns_properties_changed,
        .onNetLost = arkclash_dns_network_changed,
        .onNetUnavailable = arkclash_dns_network_unavailable,
        .onNetBlockStatusChange = arkclash_dns_block_changed,
    };
    uint32_t callbackId = 0;
    return OH_NetConn_RegisterDefaultNetConnCallback(&callbacks, &callbackId);
}

static uint64_t arkclash_dns_network_generation(void) {
    return atomic_load_explicit(&arkclash_dns_generation, memory_order_relaxed);
}

static int32_t arkclash_read_system_dns(NetConn_ConnectionProperties *properties) {
    NetConn_NetHandle handle = {0};
    int32_t result = OH_NetConn_GetDefaultNet(&handle);
    if (result != 0) {
        return result;
    }
    return OH_NetConn_GetConnectionProperties(&handle, properties);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"sync"

	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
)

var systemDNSWatcher sync.Once
var tunDNSAddr = netip.MustParseAddrPort(tunDNS).Addr()
var tunDNSAddr6 = netip.MustParseAddrPort(tunDNS6).Addr()

func init() {
	dns.SetArkClashSystemDNS(readSystemDNS, systemDNSGeneration)
}

func systemDNSGeneration() uint64 {
	// 回调只更新计数。实际读取在下一次 DNS 查询中发生，避免在回调中重入系统服务。
	systemDNSWatcher.Do(func() {
		if result := C.arkclash_watch_dns_network(); result != 0 {
			log.Warnln("[DNS] Network Kit callback registration failed: %d", int32(result))
		}
	})
	return uint64(C.arkclash_dns_network_generation())
}

func readSystemDNS() ([]string, error) {
	var properties C.NetConn_ConnectionProperties
	if result := C.arkclash_read_system_dns(&properties); result != 0 {
		return nil, fmt.Errorf("read default network DNS: %d", int32(result))
	}
	count := max(0, min(int(properties.dnsListSize), len(properties.dnsList)))
	servers := make([]string, 0, count)
	seen := make(map[netip.Addr]bool, count)
	for _, entry := range properties.dnsList[:count] {
		text := C.GoStringN(&entry.address[0], C.int(C.strnlen(&entry.address[0], C.size_t(len(entry.address)))))
		addr, err := netip.ParseAddr(text)
		if err != nil {
			continue
		}
		addr = addr.Unmap()
		if addr.IsLoopback() || addr.IsUnspecified() || addr.IsMulticast() ||
			addr == tunDNSAddr || addr.WithZone("") == tunDNSAddr6 {
			continue
		}
		if addr.Is6() && addr.IsLinkLocalUnicast() {
			if _, err := strconv.ParseUint(addr.Zone(), 10, 32); err != nil {
				properties.ifaceName[len(properties.ifaceName)-1] = 0
				index := C.if_nametoindex(&properties.ifaceName[0])
				if index == 0 {
					continue
				}
				// Go 通过 netlink 查接口名，在鸿蒙上可能失败。数字 scope 可直接交给 socket。
				addr = addr.WithZone(strconv.FormatUint(uint64(index), 10))
			}
		}
		if !seen[addr] {
			servers = append(servers, addr.String())
			seen[addr] = true
		}
	}
	if len(servers) == 0 {
		return nil, errors.New("system DNS unavailable on default network")
	}
	return servers, nil
}
