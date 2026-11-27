package engine

import (
	"fmt"
	"net/netip"
	"strings"

	"github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
)

// 地址和前缀长度须与 VpnConfig（shared/VpnNetwork.ets）及 internal/platform/system_dns.go 一致。
const (
	TunAddress  = "172.19.0.1/30"
	TunAddress6 = "fdfe:dcba:9876::1/126"
	TunDNS      = "172.19.0.2:53"
	TunDNS6     = "[fdfe:dcba:9876::2]:53"
)

type TunHandle interface {
	Close() error
}

// startTunLocked runs our own TUN listener instead of the profile's, so reloading or
// switching profiles never tears down the TUN.
func (e *Engine) startTunLocked(fd int, network TunNetworkOptions) error {
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
		DNSHijack: []string{TunDNS},
		// Routing is done by the system VPN service; netlink is off limits here.
		AutoRoute:           false,
		AutoDetectInterface: false,
		MTU:                 uint32(network.MTU),
		Inet4Address:        []netip.Prefix{netip.MustParsePrefix(TunAddress)},
		FileDescriptor:      fd,
	}
	if network.IPv6 {
		options.Inet6Address = []netip.Prefix{netip.MustParsePrefix(TunAddress6)}
		options.DNSHijack = append(options.DNSHijack, TunDNS6)
	}
	if network.DNSHijacking {
		options.DNSHijack = []string{"any:53"}
	}
	if tunStack == constant.TunMips {
		options.CongestionController = network.CongestionController
	}

	l, err := e.tunFactory(options)
	if err != nil {
		return err
	}
	e.tun = l
	e.tunCloseErr = nil
	e.tunCloseAttempted = false
	return nil
}

func (e *Engine) stopTunLocked() error {
	if e.tun == nil {
		return nil
	}
	// 清理失败保留资源不确定事实，但绝不重试可能已复用的 fd。
	if e.tunCloseAttempted {
		return e.tunCloseErr
	}
	e.tunCloseAttempted = true
	e.tunCloseErr = e.tun.Close()
	if e.tunCloseErr == nil {
		e.tun = nil
	}
	return e.tunCloseErr
}
