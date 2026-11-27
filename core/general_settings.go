package main

import (
	"context"
	"errors"
	"net"
	"os"
	"reflect"
	"strconv"
	"strings"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/auth"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/geodata"
	mihomoHttp "github.com/metacubex/mihomo/component/http"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/trie"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener"
	authStore "github.com/metacubex/mihomo/listener/auth"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

func postGeneralSettings(w http.ResponseWriter, r *http.Request) {
	var request corecfg.SettingsRequest[corecfg.GeneralSettings]
	if corecfg.DecodeSettings(r.Body, &request) != nil {
		writeError(w, r, http.StatusBadRequest, corecfg.ErrGeneralInvalid)
		return
	}
	if err := updateGeneralSettings(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrGeneralConflict) || errors.Is(err, corecfg.ErrGeneralPort) || errors.Is(err, corecfg.ErrGeneralPanel) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

type dnsRuntimeSnapshot struct {
	defaultResolver    resolver.Resolver
	defaultHostMapper  resolver.Enhancer
	defaultService     resolver.Service
	useSystemHosts     bool
	proxyHostResolver  resolver.Resolver
	directHostResolver resolver.Resolver
}

func captureDNSRuntime() dnsRuntimeSnapshot {
	return dnsRuntimeSnapshot{
		defaultResolver:    resolver.DefaultResolver,
		defaultHostMapper:  resolver.DefaultHostMapper,
		defaultService:     resolver.DefaultService,
		useSystemHosts:     resolver.UseSystemHosts,
		proxyHostResolver:  resolver.ProxyServerHostResolver,
		directHostResolver: resolver.DirectHostResolver,
	}
}

func applyLiveDNSLocked(c *config.DNS, generalIPv6 bool, target inboundSettings) {
	if !c.Enable {
		resolver.DefaultResolver = nil
		resolver.DefaultHostMapper = nil
		resolver.DefaultService = nil
		resolver.ProxyServerHostResolver = nil
		resolver.DirectHostResolver = nil
		if eng.tun != nil && target.dnsListen != "" {
			dns.ReCreateServer("", nil, nil)
		}
		return
	}

	ipv6 := c.IPv6 && generalIPv6
	r := dns.NewResolver(dns.Config{
		Main:                 c.NameServer,
		Fallback:             c.Fallback,
		IPv6:                 ipv6,
		IPv6Timeout:          c.IPv6Timeout,
		FallbackIPFilter:     c.FallbackIPFilter,
		FallbackDomainFilter: c.FallbackDomainFilter,
		FallbackLazyQuery:    c.FallbackLazyQuery,
		Default:              c.DefaultNameserver,
		Policy:               c.NameServerPolicy,
		ProxyServer:          c.ProxyServerNameserver,
		ProxyServerPolicy:    c.ProxyServerPolicy,
		DirectServer:         c.DirectNameServer,
		DirectFollowPolicy:   c.DirectFollowPolicy,
		CacheAlgorithm:       c.CacheAlgorithm,
		CacheMaxSize:         c.CacheMaxSize,
	})
	m := dns.NewEnhancer(dns.EnhancerConfig{
		IPv6:          ipv6,
		EnhancedMode:  c.EnhancedMode,
		FakeIPPool:    c.FakeIPPool,
		FakeIPPool6:   c.FakeIPPool6,
		FakeIPSkipper: c.FakeIPSkipper,
		FakeIPTTL:     c.FakeIPTTL,
		UseHosts:      c.UseHosts,
	})

	if old := resolver.DefaultHostMapper; old != nil {
		if enhancer, ok := old.(*dns.ResolverEnhancer); ok {
			m.PatchFrom(enhancer)
		}
	}

	s := dns.NewService(r, m)
	resolver.DefaultResolver = r
	resolver.DefaultHostMapper = m
	resolver.DefaultService = s
	resolver.UseSystemHosts = c.UseSystemHosts

	if r.ProxyResolver.Invalid() {
		resolver.ProxyServerHostResolver = r.ProxyResolver
	} else {
		resolver.ProxyServerHostResolver = r.Resolver
	}

	if r.DirectResolver.Invalid() {
		resolver.DirectHostResolver = r.DirectResolver
	} else {
		resolver.DirectHostResolver = r.Resolver
	}

	if eng.tun != nil && target.dnsListen != "" {
		lc := inbound.NewListenConfig()
		lc.SetRouteMark(target.dnsMark)
		dns.ReCreateServer(target.dnsListen, lc, s)
	}
}

func restoreDNSRuntimeLocked(snap dnsRuntimeSnapshot, target inboundSettings) {
	resolver.DefaultResolver = snap.defaultResolver
	resolver.DefaultHostMapper = snap.defaultHostMapper
	resolver.DefaultService = snap.defaultService
	resolver.UseSystemHosts = snap.useSystemHosts
	resolver.ProxyServerHostResolver = snap.proxyHostResolver
	resolver.DirectHostResolver = snap.directHostResolver
	if eng.tun != nil && target.dnsListen != "" {
		lc := inbound.NewListenConfig()
		lc.SetRouteMark(target.dnsMark)
		dns.ReCreateServer(target.dnsListen, lc, snap.defaultService)
	}
}

func updateGeneralSettings(request corecfg.SettingsRequest[corecfg.GeneralSettings]) error {
	return eng.withState(func(tx *stateTx) error {
		old := eng.current
		s := request.Settings
		if !profileSettingsCurrent(request.BootID, request.ExpectedRevision, old.General.Revision, s.Revision) {
			return corecfg.ErrGeneralConflict
		}
		if err := s.Validate(); err != nil {
			return err
		}
		next := old
		next.General = s
		previousInbound := eng.desiredInbound
		targetInbound := previousInbound
		baseline := previousInbound.baseline

		hostsChanged := !reflect.DeepEqual(old.General.Hosts, s.Hosts)
		uaChanged := old.General.UserAgent != s.UserAgent
		appendDNSChanged := old.General.AppendSystemDNS != s.AppendSystemDNS
		var oldOverrides, nextOverrides corecfg.GeneralCoreOverrides
		if old.General.CoreOverrides != nil {
			oldOverrides = *old.General.CoreOverrides
		}
		if s.CoreOverrides != nil {
			nextOverrides = *s.CoreOverrides
		}
		unifiedChanged := !corecfg.SameBoolPtr(oldOverrides.UnifiedDelay, nextOverrides.UnifiedDelay)
		tcpChanged := !corecfg.SameBoolPtr(oldOverrides.TCPConcurrent, nextOverrides.TCPConcurrent)
		ipv6Changed := !corecfg.SameBoolPtr(oldOverrides.IPv6, nextOverrides.IPv6)
		loaderChanged := !corecfg.SameStringPtr(oldOverrides.GeodataLoader, nextOverrides.GeodataLoader)
		liveGeneralChanged := hostsChanged || uaChanged || appendDNSChanged ||
			unifiedChanged || tcpChanged || ipv6Changed || loaderChanged

		rebuild := s.Ports == nil && old.General.Ports != nil ||
			s.Authentication == nil && old.General.Authentication != nil ||
			(liveGeneralChanged && !baseline.Ready())
		if !rebuild && baseline.Ready() && baseline.DNSConfig() != nil {
			nextIPv6 := baseline.EffectiveIPv6(s)
			// 开启 IPv6 且原配置因禁用 IPv6 跳过了 fake-ip-range6 初始化时，走完整重建以交由内核校验 IPv6 环境。
			if ipv6Changed && nextIPv6 && baseline.DNSHasFakeIPRange6() && !baseline.DNSConfig().FakeIPRange6.IsValid() {
				rebuild = true
			}
			if ipv6Changed && !nextIPv6 && baseline.DNSConfig().EnhancedMode == C.DNSFakeIP && !baseline.DNSConfig().FakeIPRange.IsValid() {
				rebuild = true
			}
			if (appendDNSChanged || ipv6Changed) && baseline.DNSConfig().Enable && len(baseline.DNSServers(next.Profile, s.AppendSystemDNS)) == 0 {
				rebuild = true
			}
		}

		var (
			cfg       *config.Config
			nextHosts *trie.DomainTrie[resolver.HostValue]
			nextDNS   *config.DNS
		)
		if rebuild {
			var err error
			cfg, err = parseProfileSettingsConfig(&next, &targetInbound)
			if err != nil {
				return corecfg.ErrGeneralApply
			}
		} else {
			if s.Ports != nil {
				p := s.Ports
				b := &targetInbound.inbound
				b.MixedPort, b.Port, b.SocksPort, b.RedirPort, b.TProxyPort = p.Mixed, p.HTTP, p.SOCKS, p.Redir, p.TProxy
			}
			if hostsChanged {
				var err error
				nextHosts, err = corecfg.BuildMergedHosts(baseline.RawHosts(), s.Hosts)
				if err != nil {
					return corecfg.ErrGeneralApply
				}
			}
			dnsChanged := (appendDNSChanged && next.Profile != "" && !baseline.DNSAlreadyHasSystem()) || ipv6Changed
			if dnsChanged && baseline.DNSConfig() != nil {
				var err error
				nextDNS, err = corecfg.BuildLiveDNSConfig(baseline, next.Profile, s.AppendSystemDNS, baseline.EffectiveIPv6(s))
				if err != nil {
					return corecfg.ErrGeneralApply
				}
			}
		}
		if err := preflightGeneralPorts(targetInbound, s.ControllerSecret != ""); err != nil {
			return err
		}
		path := corecfg.GeneralSettingsPath(old.HomeDir)
		staged, err := corecfg.StageSettings(path, s)
		if err != nil {
			return corecfg.ErrGeneralIO
		}
		defer os.Remove(staged)
		if err := setPanelControllerLocked(s.ControllerSecret); err != nil {
			eng.publishRuntimeLocked()
			return corecfg.ErrGeneralPanel
		}

		oldAuth := authStore.Default.Authenticator()
		oldUA := mihomoHttp.UA()
		oldUnified := adapter.UnifiedDelay.Load()
		oldTCP := dialer.GetTcpConcurrent()
		oldDisableIPv6 := resolver.DisableIPv6
		oldLoader := geodata.LoaderName()
		oldHosts := resolver.DefaultHosts
		oldDNS := captureDNSRuntime()
		appliedLive := false

		appliedReload := false
		if rebuild {
			appliedReload, err = tx.CommitReload(reloadPlan{
				Next:                 next,
				Cfg:                  cfg,
				Inbound:              targetInbound,
				AllowInboundRollback: true,
			})
		} else {
			err = applyGeneralListenersLocked(targetInbound, s.Authentication)
			if err == nil && liveGeneralChanged {
				appliedLive = true
				if uaChanged {
					mihomoHttp.SetUA(baseline.EffectiveUA(s))
				}
				if unifiedChanged {
					adapter.UnifiedDelay.Store(baseline.EffectiveUnifiedDelay(s))
				}
				if tcpChanged {
					dialer.SetTcpConcurrent(baseline.EffectiveTCPConcurrent(s))
				}
				if loaderChanged {
					geodata.SetLoader(baseline.EffectiveGeodataLoader(s))
				}
				if ipv6Changed {
					resolver.DisableIPv6 = !baseline.EffectiveIPv6(s)
				}
				if hostsChanged {
					resolver.DefaultHosts = resolver.NewHosts(nextHosts)
				}
				if nextDNS != nil {
					applyLiveDNSLocked(nextDNS, baseline.EffectiveIPv6(s), targetInbound)
				}
			}
		}
		if err == nil {
			if os.Rename(staged, path) == nil {
				if nextDNS != nil {
					if oldDNS.defaultResolver != nil {
						oldDNS.defaultResolver.ResetConnection()
					}
					resolver.ResetConnection()
				}
				eng.current = next
				log.SetLevel(s.Level())
				if !rebuild {
					tx.deferUnlock(eng.diag.SetCaptureLogs(s.CaptureLogs))
				}
				eng.publishRuntimeLocked()
				return nil
			}
			err = corecfg.ErrGeneralIO
		} else {
			err = corecfg.ErrGeneralPort
		}

		if rebuild && appliedReload {
			_ = tx.RollbackReload(old, previousInbound)
		} else if !rebuild {
			if appliedLive {
				mihomoHttp.SetUA(oldUA)
				adapter.UnifiedDelay.Store(oldUnified)
				dialer.SetTcpConcurrent(oldTCP)
				geodata.SetLoader(oldLoader)
				resolver.DisableIPv6 = oldDisableIPv6
				resolver.DefaultHosts = oldHosts
				if nextDNS != nil {
					restoreDNSRuntimeLocked(oldDNS, previousInbound)
				}
			}
			authStore.Default.SetAuthenticator(oldAuth)
			inbound.SetSkipAuthPrefixes(previousInbound.inbound.SkipAuthPrefixes)
			if rollbackErr := applyGeneralListenersLocked(previousInbound, nil); rollbackErr != nil {
				eng.cleanupFailure = errors.Join(eng.cleanupFailure, closeBusinessInbounds(), stopTun(), rollbackErr)
			}
		}
		if setPanelControllerLocked(old.General.ControllerSecret) != nil {
			err = corecfg.ErrGeneralApply
		}
		eng.setCurrentLocked(old)
		log.SetLevel(old.General.Level())
		return err
	})
}

func portsFromInbound(b config.Inbound) corecfg.GeneralPorts {
	return corecfg.GeneralPorts{Mixed: b.MixedPort, HTTP: b.Port, SOCKS: b.SocksPort, Redir: b.RedirPort, TProxy: b.TProxyPort}
}

func preflightGeneralPorts(target inboundSettings, panel bool) error {
	b := target.inbound
	ports := portsFromInbound(b).Values()
	address := "127.0.0.1"
	if b.AllowLan && b.BindAddress == "*" {
		address = ""
	} else if b.AllowLan {
		address = strings.Trim(b.BindAddress, "[]")
	}
	active := listener.GetPorts()
	for i, port := range ports {
		if port == 0 {
			continue
		}
		if port == 19090 || panel && port == corecfg.PanelPort {
			return corecfg.ErrGeneralPort
		}
		if eng.tun == nil || port == active.Port || port == active.SocksPort || port == active.RedirPort ||
			port == active.TProxyPort || port == active.MixedPort {
			continue
		}
		addr := net.JoinHostPort(address, strconv.Itoa(port))
		var lc net.ListenConfig
		socket, err := lc.Listen(context.Background(), "tcp", addr)
		if err != nil {
			return corecfg.ErrGeneralPort
		}
		_ = socket.Close()
		if i == 0 || i == 2 || i == 4 {
			packet, err := lc.ListenPacket(context.Background(), "udp", addr)
			if err != nil {
				return corecfg.ErrGeneralPort
			}
			_ = packet.Close()
		}
	}
	return nil
}

func applyGeneralListenersLocked(target inboundSettings, a *corecfg.GeneralAuthentication) error {
	if a != nil {
		var users []auth.AuthUser
		if a.Enabled {
			users = []auth.AuthUser{{User: a.Username, Pass: a.Password}}
		}
		authStore.Default.SetAuthenticator(auth.NewAuthenticator(users))
		target.inbound.SkipAuthPrefixes = nil
		inbound.SetSkipAuthPrefixes(nil)
	}
	eng.desiredInbound = target
	if eng.tun == nil {
		return nil
	}
	old := listener.GetPorts()
	prior := corecfg.GeneralPorts{Mixed: old.MixedPort, HTTP: old.Port, SOCKS: old.SocksPort, Redir: old.RedirPort, TProxy: old.TProxyPort}.Values()
	next := portsFromInbound(target.inbound).Values()
	rebind := [...]func(int, C.Tunnel){
		listener.ReCreateMixed, listener.ReCreateHTTP, listener.ReCreateSocks, listener.ReCreateRedir, listener.ReCreateTProxy,
	}
	for i, bind := range rebind {
		if prior[i] != next[i] && prior[i] != 0 {
			bind(0, tunnel.Tunnel)
		}
	}
	for i, bind := range rebind {
		if prior[i] != next[i] && next[i] != 0 {
			bind(next[i], tunnel.Tunnel)
		}
	}
	active := listener.GetPorts()
	if (corecfg.GeneralPorts{Mixed: active.MixedPort, HTTP: active.Port, SOCKS: active.SocksPort, Redir: active.RedirPort, TProxy: active.TProxyPort}) != portsFromInbound(target.inbound) {
		return corecfg.ErrGeneralPort
	}
	return nil
}
