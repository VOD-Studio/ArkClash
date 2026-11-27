package main

import (
	"fmt"
	"net/netip"
	"strings"

	"github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
)

// 地址和前缀长度须与 VpnConfig 一致。
const (
	tunAddress  = "172.19.0.1/30"
	tunAddress6 = "fdfe:dcba:9876::1/126"
	tunDNS      = "172.19.0.2:53"
	tunDNS6     = "[fdfe:dcba:9876::2]:53"
)

type tunHandle interface {
	Close() error
}

// startTun runs our own TUN listener instead of the profile's, so reloading or
// switching profiles never tears down the TUN.
func startTun(fd int, network tunNetworkOptions) error {
	tunStack, ok := constant.StackTypeMapping[strings.ToLower(network.Stack)]
	if !ok {
		return fmt.Errorf("unknown tun stack %q", network.Stack)
	}
	minMTU := 576
	if network.IPv6 {
		minMTU = 1280
	}
	if network.MTU < minMTU || network.MTU > 1500 {
		return fmt.Errorf("invalid tun mtu %d", network.MTU)
	}

	options := LC.Tun{
		Enable:    true,
		Device:    "arkclash",
		Stack:     tunStack,
		DNSHijack: []string{tunDNS},
		// Routing is done by the system VPN service; netlink is off limits here.
		AutoRoute:           false,
		AutoDetectInterface: false,
		MTU:                 uint32(network.MTU),
		Inet4Address:        []netip.Prefix{netip.MustParsePrefix(tunAddress)},
		FileDescriptor:      fd,
	}
	if network.IPv6 {
		options.Inet6Address = []netip.Prefix{netip.MustParsePrefix(tunAddress6)}
		options.DNSHijack = append(options.DNSHijack, tunDNS6)
	}
	if network.DNSHijacking {
		options.DNSHijack = []string{"any:53"}
	}
	if tunStack == constant.TunMips {
		options.CongestionController = network.CongestionController
	}

	l, err := eng.tunFactory(options)
	if err != nil {
		return err
	}
	eng.tun = l
	eng.tunCloseErr = nil
	eng.tunCloseAttempted = false
	return nil
}

func stopTun() error {
	if eng.tun == nil {
		return nil
	}
	// 清理失败保留资源不确定事实，但绝不重试可能已复用的 fd。
	if eng.tunCloseAttempted {
		return eng.tunCloseErr
	}
	eng.tunCloseAttempted = true
	eng.tunCloseErr = eng.tun.Close()
	if eng.tunCloseErr == nil {
		eng.tun = nil
	}
	return eng.tunCloseErr
}
