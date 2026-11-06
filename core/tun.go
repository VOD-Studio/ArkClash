package main

import (
	"fmt"
	"net/netip"
	"strings"

	"github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/tunnel"
)

// These must match the VpnConfig built in ClashVpnAbility.ets.
const (
	tunAddress = "172.19.0.1/30"
	tunMTU     = 1500 // HarmonyOS caps VpnConfig.mtu at 1500
)

var tunListener *sing_tun.Listener

// startTun runs our own TUN listener instead of the profile's, so reloading or
// switching profiles never tears down the TUN.
func startTun(fd int, stack string) error {
	// gVisor is the default: the whole TCP/IP stack stays in user space, so it
	// does not depend on how protectProcessNet() marks kernel sockets.
	tunStack := constant.TunGvisor
	if stack != "" {
		s, ok := constant.StackTypeMapping[strings.ToLower(stack)]
		if !ok {
			return fmt.Errorf("unknown tun stack %q", stack)
		}
		tunStack = s
	}

	options := LC.Tun{
		Enable: true,
		Device: "arkclash",
		Stack:  tunStack,
		DNSHijack: []string{
			"any:53",
			"tcp://any:53",
		},
		// Routing is done by the system VPN service; netlink is off limits here.
		AutoRoute:           false,
		AutoDetectInterface: false,
		MTU:                 tunMTU,
		Inet4Address:        []netip.Prefix{netip.MustParsePrefix(tunAddress)},
		FileDescriptor:      fd,
	}

	l, err := sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		return err
	}
	tunListener = l
	return nil
}

func stopTun() {
	if tunListener != nil {
		_ = tunListener.Close()
		tunListener = nil
	}
}
