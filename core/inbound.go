package main

import (
	"errors"
	"fmt"
	"reflect"

	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
)

// 只保存重开入口与常规设置原地热更新所需的数据，不能延长旧节点、provider 或 resolver 的寿命。
type inboundSettings struct {
	inbound   config.Inbound
	custom    []map[string]any
	tunnels   []LC.Tunnel
	dnsListen string
	dnsMark   int
	baseline  generalBaseline
}

var desiredInbound inboundSettings
var cleanupFailure error

func captureInbound(cfg *config.Config, mappings []map[string]any) inboundSettings {
	return inboundSettings{inbound: cfg.General.Inbound, custom: mappings, tunnels: cfg.Tunnels,
		dnsListen: cfg.DNS.Listen, dnsMark: cfg.DNS.ListenRoutingMark}
}

func withoutBusinessInbounds(cfg *config.Config) *config.Config {
	next := *cfg
	general := *cfg.General
	general.Port, general.SocksPort, general.RedirPort, general.TProxyPort, general.MixedPort = 0, 0, 0, 0, 0
	general.ShadowSocksConfig, general.VmessConfig = "", ""
	general.TuicServer = LC.TuicServer{}
	general.Tun = LC.Tun{}
	next.General = &general
	dnsConfig := *cfg.DNS
	dnsConfig.Listen = ""
	next.DNS = &dnsConfig
	next.Listeners = nil
	next.Tunnels = nil
	return &next
}

func businessListenersOpen() bool {
	p := listener.GetPorts()
	s := listener.ArkClashListenerSnapshot()
	tcp, udp := dns.ArkClashServerSnapshot()
	return p.Port != 0 || p.SocksPort != 0 || p.RedirPort != 0 || p.TProxyPort != 0 || p.MixedPort != 0 ||
		p.ShadowSocksConfig != "" || p.VmessConfig != "" || listener.GetTuicConf().Enable ||
		len(s.Inbound) != 0 || len(s.TCPTunnels) != 0 || len(s.UDPTunnels) != 0 || tcp != "" || udp != ""
}

func closeBusinessInbounds() error {
	// 注册表只调用 mihomo 内部的取消与 Close，不会重入核心 mu。
	err := errors.Join(tunnel.ArkClashSuspendForwarding(), listener.ArkClashCloseListeners(), dns.ArkClashCloseServer())
	if businessListenersOpen() {
		err = errors.Join(err, errors.New("business listeners remain open"))
	}
	return err
}

func restoreBusinessInbounds() error {
	s := desiredInbound
	custom := make(map[string]C.InboundListener, len(s.custom))
	for _, mapping := range s.custom {
		// ParseListener 只读原始映射；JSON 往返会把整数端口变成浮点数。
		l, err := listener.ParseListener(mapping)
		if err != nil {
			return err
		}
		custom[l.Name()] = l
	}
	b := s.inbound
	listener.SetAllowLan(b.AllowLan)
	listener.SetBindAddress(b.BindAddress)
	inbound.SetSkipAuthPrefixes(b.SkipAuthPrefixes)
	inbound.SetAllowedIPs(b.LanAllowedIPs)
	inbound.SetDisAllowedIPs(b.LanDisAllowedIPs)
	listener.ReCreateHTTP(b.Port, tunnel.Tunnel)
	listener.ReCreateSocks(b.SocksPort, tunnel.Tunnel)
	listener.ReCreateRedir(b.RedirPort, tunnel.Tunnel)
	listener.ReCreateTProxy(b.TProxyPort, tunnel.Tunnel)
	listener.ReCreateMixed(b.MixedPort, tunnel.Tunnel)
	listener.ReCreateShadowSocks(b.ShadowSocksConfig, tunnel.Tunnel)
	listener.ReCreateVmess(b.VmessConfig, tunnel.Tunnel)
	listener.ReCreateTuic(b.TuicServer, tunnel.Tunnel)
	listener.PatchInboundListeners(custom, tunnel.Tunnel, true)
	listener.PatchTunnel(s.tunnels, tunnel.Tunnel)
	lc := inbound.NewListenConfig()
	lc.SetRouteMark(s.dnsMark)
	dns.ReCreateServer(s.dnsListen, lc, resolver.DefaultService)
	if err := verifyBusinessInbounds(custom); err != nil {
		return err
	}
	tunnel.ArkClashResumeForwarding()
	return nil
}

func verifyBusinessInbounds(custom map[string]C.InboundListener) error {
	b := desiredInbound.inbound
	want := listener.Ports{Port: b.Port, SocksPort: b.SocksPort, RedirPort: b.RedirPort, TProxyPort: b.TProxyPort,
		MixedPort: b.MixedPort, ShadowSocksConfig: b.ShadowSocksConfig, VmessConfig: b.VmessConfig}
	if !reflect.DeepEqual(*listener.GetPorts(), want) {
		return errors.New("business port binding failed")
	}
	if !reflect.DeepEqual(listener.GetTuicConf(), b.TuicServer) && (b.TuicServer.Enable || listener.GetTuicConf().Enable) {
		return errors.New("TUIC binding failed")
	}
	s := listener.ArkClashListenerSnapshot()
	if len(s.Inbound) != len(custom) {
		return errors.New("custom listener binding failed")
	}
	for name := range custom {
		if !s.Inbound[name] {
			return fmt.Errorf("custom listener binding failed: %s", name)
		}
	}
	tcpWant, udpWant := make(map[string]bool), make(map[string]bool)
	for _, t := range desiredInbound.tunnels {
		key := fmt.Sprintf("%s/%s/%s", t.Address, t.Target, t.Proxy)
		for _, network := range t.Network {
			if network == "tcp" {
				tcpWant[key] = true
			} else {
				udpWant[key] = true
			}
		}
	}
	if !reflect.DeepEqual(s.TCPTunnels, tcpWant) || !reflect.DeepEqual(s.UDPTunnels, udpWant) {
		return errors.New("tunnel binding failed")
	}
	tcp, udp := dns.ArkClashServerSnapshot()
	if desiredInbound.dnsListen != "" && (tcp == "" || udp == "") {
		return errors.New("DNS binding failed")
	}
	if desiredInbound.dnsListen == "" && (tcp != "" || udp != "") {
		return errors.New("unexpected DNS listener")
	}
	return nil
}
