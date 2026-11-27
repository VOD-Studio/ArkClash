package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"os"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"unicode"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/auth"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/fakeip"
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

type generalPorts struct {
	Mixed  int `json:"mixed"`
	HTTP   int `json:"http"`
	SOCKS  int `json:"socks"`
	Redir  int `json:"redir"`
	TProxy int `json:"tproxy"`
}

type generalAuthentication struct {
	Enabled  bool   `json:"enabled"`
	Username string `json:"username"`
	Password string `json:"password"`
}

// 内核可选覆写项；指针为 nil 表示未覆写，沿用配置或内核默认值。
type generalCoreOverrides struct {
	TestURL       *string `json:"testUrl,omitempty"`
	UnifiedDelay  *bool   `json:"unifiedDelay,omitempty"`
	TCPConcurrent *bool   `json:"tcpConcurrent,omitempty"`
	IPv6          *bool   `json:"ipv6,omitempty"`
	GeodataLoader *string `json:"geodataLoader,omitempty"`
}

type generalSettings struct {
	Revision         string                 `json:"revision"`
	Ports            *generalPorts          `json:"ports,omitempty"`
	Authentication   *generalAuthentication `json:"authentication,omitempty"`
	ControllerSecret string                 `json:"controllerSecret"`
	UserAgent        string                 `json:"userAgent"`
	UserAgents       []string               `json:"userAgents,omitempty"`
	AppendSystemDNS  bool                   `json:"appendSystemDns,omitempty"`
	Hosts            map[string][]string    `json:"hosts"`
	DelayTimeout     int                    `json:"delayTimeout"`
	CloseConnections *bool                  `json:"closeConnections,omitempty"`
	LogLevel         string                 `json:"logLevel"`
	CaptureLogs      bool                   `json:"captureLogs"`
	CoreOverrides    *generalCoreOverrides  `json:"coreOverrides,omitempty"`
}

const panelPort = 9090

var errGeneralInvalid = errors.New("general_settings_invalid")
var errGeneralConflict = errors.New("general_settings_conflict")
var errGeneralIO = errors.New("general_settings_io")
var errGeneralApply = errors.New("general_settings_apply_failed")
var errGeneralPort = errors.New("general_settings_port_busy")
var errGeneralPanel = errors.New("general_settings_controller_busy")

func (p generalPorts) values() [5]int {
	return [5]int{p.Mixed, p.HTTP, p.SOCKS, p.Redir, p.TProxy}
}

func (s generalSettings) level() log.LogLevel {
	if level, ok := log.LogLevelMapping[s.LogLevel]; ok {
		return level
	}
	return log.ERROR
}

func validGeneralText(value string, limit int) bool {
	return len(value) <= limit && strings.TrimSpace(value) == value &&
		strings.IndexFunc(value, unicode.IsControl) == -1
}

func (s generalSettings) validate() error {
	if !validGeneralText(s.Revision, 96) || s.Revision == "" || !validGeneralText(s.UserAgent, 512) {
		return errGeneralInvalid
	}
	if len(s.UserAgents) > 64 {
		return errGeneralInvalid
	}
	agents := make(map[string]bool, len(s.UserAgents))
	for _, agent := range s.UserAgents {
		if agent == "" || !validGeneralText(agent, 512) || agents[agent] {
			return errGeneralInvalid
		}
		agents[agent] = true
	}
	switch s.DelayTimeout {
	case 500, 1000, 2000, 5000, 8000:
	default:
		return errGeneralInvalid
	}
	if _, ok := log.LogLevelMapping[s.LogLevel]; !ok {
		return errGeneralInvalid
	}
	if s.ControllerSecret != "" && (!validGeneralText(s.ControllerSecret, 512) ||
		strings.ContainsAny(s.ControllerSecret, " \t")) {
		return errGeneralInvalid
	}
	if s.Ports != nil {
		seen := map[int]bool{19090: true}
		if s.ControllerSecret != "" {
			seen[panelPort] = true
		}
		if s.Ports.Mixed == 0 {
			return errGeneralInvalid
		}
		for _, port := range s.Ports.values() {
			if port == 0 {
				continue
			}
			if port < 1024 || port > 49151 || seen[port] {
				return errGeneralInvalid
			}
			seen[port] = true
		}
	}
	if a := s.Authentication; a != nil {
		if !validGeneralText(a.Username, 128) || !validGeneralText(a.Password, 512) ||
			strings.Contains(a.Username, ":") || (a.Enabled && (a.Username == "" || a.Password == "")) {
			return errGeneralInvalid
		}
	}
	if err := validateGeneralCoreOverrides(s.CoreOverrides); err != nil {
		return err
	}
	return validateGeneralHosts(s.Hosts)
}

func validGeneralTestURL(value string) bool {
	if value == "" || !validGeneralText(value, 2048) || strings.ContainsAny(value, " \t") {
		return false
	}
	parsed, err := url.Parse(value)
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Hostname() != ""
}

func validateGeneralCoreOverrides(overrides *generalCoreOverrides) error {
	if overrides == nil {
		return nil
	}
	if overrides.TestURL != nil && !validGeneralTestURL(*overrides.TestURL) {
		return errGeneralInvalid
	}
	if overrides.GeodataLoader != nil &&
		*overrides.GeodataLoader != "standard" && *overrides.GeodataLoader != "memconservative" {
		return errGeneralInvalid
	}
	return nil
}

func sameBoolPtr(left, right *bool) bool {
	if left == nil || right == nil {
		return left == right
	}
	return *left == *right
}

func sameStringPtr(left, right *string) bool {
	if left == nil || right == nil {
		return left == right
	}
	return *left == *right
}

func validateGeneralHosts(hosts map[string][]string) error {
	if len(hosts) > 256 {
		return errGeneralInvalid
	}
	keys := trie.New[struct{}]()
	domains := make(map[string]bool)
	aliases := make(map[string]string)
	for domain, values := range hosts {
		key := strings.ToLower(domain)
		if !validHostName(domain) || domains[key] || keys.Insert(domain, struct{}{}) != nil ||
			len(values) == 0 || len(values) > 32 {
			return errGeneralInvalid
		}
		domains[key] = true
		for _, value := range values {
			if addr, err := netip.ParseAddr(value); err == nil {
				if addr.Zone() != "" {
					return errGeneralInvalid
				}
			} else if !validHostName(value) {
				return errGeneralInvalid
			}
		}
		resolved, err := resolver.NewHostValue(values)
		if err != nil {
			return errGeneralInvalid
		}
		if resolved.IsDomain {
			aliases[key] = strings.ToLower(resolved.Domain)
		}
	}
	for domain := range aliases {
		seen := make(map[string]bool)
		for next := domain; next != ""; next = aliases[next] {
			if seen[next] {
				return errGeneralInvalid
			}
			seen[next] = true
		}
	}
	return nil
}

func validHostName(value string) bool {
	return value != "" && validGeneralText(value, 512) && !strings.ContainsAny(value, " /:?#@\t")
}

func generalSettingsPath(home string) string { return portableDataPath(home, "general-settings.json") }

func readGeneralSettings(home string) (generalSettings, error) {
	file, err := os.Open(generalSettingsPath(home))
	if errors.Is(err, os.ErrNotExist) {
		return generalSettings{Revision: "default", DelayTimeout: 8000, LogLevel: "error"}, nil
	}
	if err != nil {
		return generalSettings{}, errGeneralIO
	}
	defer file.Close()
	var settings generalSettings
	if err := decodeProfileSettings(file, &settings); err != nil {
		return settings, errGeneralInvalid
	}
	return settings, settings.validate()
}

func (s generalSettings) apply(raw *config.RawConfig) {
	raw.LogLevel = s.level()
	if s.UserAgent != "" {
		raw.GlobalUA = s.UserAgent
	}
	if p := s.Ports; p != nil {
		raw.MixedPort, raw.Port, raw.SocksPort, raw.RedirPort, raw.TProxyPort = p.Mixed, p.HTTP, p.SOCKS, p.Redir, p.TProxy
	}
	if a := s.Authentication; a != nil {
		raw.Authentication = nil
		raw.SkipAuthPrefixes = nil
		if a.Enabled {
			raw.Authentication = []string{a.Username + ":" + a.Password}
		}
	}
	if len(s.Hosts) != 0 && raw.Hosts == nil {
		raw.Hosts = make(map[string]any, len(s.Hosts))
	}
	for domain, values := range s.Hosts {
		for original := range raw.Hosts {
			if original != domain && strings.EqualFold(original, domain) {
				delete(raw.Hosts, original)
			}
		}
		raw.Hosts[domain] = values
	}
	if o := s.CoreOverrides; o != nil {
		if o.UnifiedDelay != nil {
			raw.UnifiedDelay = *o.UnifiedDelay
		}
		if o.TCPConcurrent != nil {
			raw.TCPConcurrent = *o.TCPConcurrent
		}
		if o.IPv6 != nil {
			raw.IPv6 = *o.IPv6
		}
		if o.GeodataLoader != nil {
			raw.GeodataLoader = *o.GeodataLoader
		}
	}
}

func postGeneralSettings(w http.ResponseWriter, r *http.Request) {
	var request profileSettingsRequest[generalSettings]
	if decodeProfileSettings(r.Body, &request) != nil {
		writeError(w, r, http.StatusBadRequest, errGeneralInvalid)
		return
	}
	if err := updateGeneralSettings(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errGeneralConflict) || errors.Is(err, errGeneralPort) || errors.Is(err, errGeneralPanel) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

// 记录当前生效配置在应用常规覆写前的基线，使请求与内核设置可原地热更新并恢复配置原值。
type generalBaseline struct {
	ready               bool
	globalUA            string
	unifiedDelay        bool
	tcpConcurrent       bool
	ipv6                bool
	geodataLoader       string
	rawHosts            map[string]any
	storeFakeIP         bool
	dnsAlreadyHasSystem bool
	dnsRespectRules     bool
	dnsHasFakeIPRange6  bool
	dnsConfig           *config.DNS
	dnsBaseServers      []dns.NameServer
}

type dnsRuntimeSnapshot struct {
	defaultResolver    resolver.Resolver
	defaultHostMapper  resolver.Enhancer
	defaultService     resolver.Service
	useSystemHosts     bool
	proxyHostResolver  resolver.Resolver
	directHostResolver resolver.Resolver
}

func cloneRawHosts(source map[string]any) map[string]any {
	if len(source) == 0 {
		return nil
	}
	cloned := make(map[string]any, len(source))
	for key, value := range source {
		cloned[key] = value
	}
	return cloned
}

func captureRawGeneralBaseline(rawCfg *config.RawConfig, opts startOptions) generalBaseline {
	rawServers := rawCfg.DNS.NameServer
	if opts.Profile != "" && opts.DNS.Entries.Servers != nil {
		rawServers = *opts.DNS.Entries.Servers
	}
	return generalBaseline{
		globalUA:            rawCfg.GlobalUA,
		unifiedDelay:        rawCfg.UnifiedDelay,
		tcpConcurrent:       rawCfg.TCPConcurrent,
		ipv6:                rawCfg.IPv6,
		geodataLoader:       rawCfg.GeodataLoader,
		rawHosts:            cloneRawHosts(rawCfg.Hosts),
		storeFakeIP:         rawCfg.Profile.StoreFakeIP,
		dnsAlreadyHasSystem: hasSystemDNS(rawServers),
	}
}

func systemDNSNameServer(respectRules, preferH3 bool) dns.NameServer {
	proxyName := ""
	if respectRules {
		proxyName = dns.RespectRules
	}
	return dns.NameServer{
		Net:       "system",
		ProxyName: proxyName,
		Params:    map[string]string{},
		PreferH3:  preferH3,
	}
}

func (b *generalBaseline) finalizeDNS(parsed *config.DNS, appendedSystem bool) {
	if parsed != nil {
		dnsCopy := *parsed
		dnsCopy.FakeIPPool = nil
		dnsCopy.FakeIPPool6 = nil
		dnsCopy.NameServer = nil
		servers := slices.Clone(parsed.NameServer)
		if appendedSystem && !b.dnsAlreadyHasSystem && len(servers) > 0 {
			systemNS := systemDNSNameServer(b.dnsRespectRules, dnsCopy.PreferH3)
			if servers[len(servers)-1].Equal(systemNS) {
				servers = servers[:len(servers)-1]
			}
		}
		b.dnsConfig = &dnsCopy
		b.dnsBaseServers = servers
	}
	b.ready = true
}

func (b generalBaseline) effectiveUA(s generalSettings) string {
	if s.UserAgent != "" {
		return s.UserAgent
	}
	return b.globalUA
}

func (b generalBaseline) effectiveUnifiedDelay(s generalSettings) bool {
	if s.CoreOverrides != nil && s.CoreOverrides.UnifiedDelay != nil {
		return *s.CoreOverrides.UnifiedDelay
	}
	return b.unifiedDelay
}

func (b generalBaseline) effectiveTCPConcurrent(s generalSettings) bool {
	if s.CoreOverrides != nil && s.CoreOverrides.TCPConcurrent != nil {
		return *s.CoreOverrides.TCPConcurrent
	}
	return b.tcpConcurrent
}

func (b generalBaseline) effectiveIPv6(s generalSettings) bool {
	if s.CoreOverrides != nil && s.CoreOverrides.IPv6 != nil {
		return *s.CoreOverrides.IPv6
	}
	return b.ipv6
}

func (b generalBaseline) effectiveGeodataLoader(s generalSettings) string {
	if s.CoreOverrides != nil && s.CoreOverrides.GeodataLoader != nil {
		return *s.CoreOverrides.GeodataLoader
	}
	return b.geodataLoader
}

func (b generalBaseline) dnsServers(profile string, appendSystem bool) []dns.NameServer {
	servers := slices.Clone(b.dnsBaseServers)
	if profile != "" && appendSystem && !b.dnsAlreadyHasSystem && b.dnsConfig != nil {
		systemNS := systemDNSNameServer(b.dnsRespectRules, b.dnsConfig.PreferH3)
		if !slices.ContainsFunc(servers, systemNS.Equal) {
			servers = append(servers, systemNS)
		}
	}
	return servers
}

func buildMergedHosts(base map[string]any, overrides map[string][]string) (*trie.DomainTrie[resolver.HostValue], error) {
	merged := cloneRawHosts(base)
	if len(overrides) > 0 && merged == nil {
		merged = make(map[string]any, len(overrides))
	}
	for domain, values := range overrides {
		for original := range merged {
			if original != domain && strings.EqualFold(original, domain) {
				delete(merged, original)
			}
		}
		merged[domain] = values
	}

	tree := trie.New[resolver.HostValue]()
	localhost, _ := resolver.NewHostValueByIPs([]netip.Addr{netip.AddrFrom4([4]byte{127, 0, 0, 1})})
	if err := tree.Insert("localhost", localhost); err != nil {
		log.Errorln("insert localhost to host error: %s", err.Error())
	}

	for domain, anyValue := range merged {
		hosts, err := utils.ToStringSlice(anyValue)
		if err != nil {
			return nil, err
		}
		if len(hosts) == 1 && hosts[0] == "lan" {
			if addrs, err := net.InterfaceAddrs(); err != nil {
				log.Errorln("insert lan to host error: %s", err)
			} else {
				hosts = make([]string, 0, len(addrs))
				for _, addr := range addrs {
					if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && !ipnet.IP.IsLinkLocalUnicast() {
						hosts = append(hosts, ipnet.IP.String())
					}
				}
			}
		}
		value, err := resolver.NewHostValue(hosts)
		if err != nil {
			return nil, fmt.Errorf("%s is not a valid value", anyValue)
		}
		if value.IsDomain {
			node := tree.Search(value.Domain)
			for node != nil && node.Data().IsDomain {
				if node.Data().Domain == domain {
					return nil, fmt.Errorf("%s, there is a cycle in domain name mapping", domain)
				}
				node = tree.Search(node.Data().Domain)
			}
		}
		if err := tree.Insert(domain, value); err != nil {
			log.Warnln("skip invalid hosts entry: %s", err)
		}
	}
	tree.Optimize()
	return tree, nil
}

func buildLiveDNSConfig(base generalBaseline, profile string, appendSystem, effectiveIPv6 bool) (*config.DNS, error) {
	if base.dnsConfig == nil {
		return nil, nil
	}
	dnsCfg := *base.dnsConfig
	dnsCfg.NameServer = base.dnsServers(profile, appendSystem)
	if dnsCfg.Enable && dnsCfg.EnhancedMode == C.DNSFakeIP {
		// 必须分配全新的 FakeIP 池，避免 PatchFrom 对同一池重入加锁死锁。
		if dnsCfg.FakeIPRange.IsValid() {
			pool, err := fakeip.New(fakeip.Options{
				IPNet:       dnsCfg.FakeIPRange,
				Size:        1000,
				Persistence: base.storeFakeIP,
			})
			if err != nil {
				return nil, err
			}
			dnsCfg.FakeIPPool = pool
		}
		if effectiveIPv6 && dnsCfg.IPv6 && dnsCfg.FakeIPRange6.IsValid() {
			pool6, err := fakeip.New(fakeip.Options{
				IPNet:       dnsCfg.FakeIPRange6,
				Size:        1000,
				Persistence: base.storeFakeIP,
			})
			if err != nil {
				return nil, err
			}
			dnsCfg.FakeIPPool6 = pool6
		}
	}
	return &dnsCfg, nil
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

func updateGeneralSettings(request profileSettingsRequest[generalSettings]) error {
	return eng.withState(func(tx *stateTx) error {
		old := eng.current
		s := request.Settings
		if !profileSettingsCurrent(request.BootID, request.ExpectedRevision, old.General.Revision, s.Revision) {
			return errGeneralConflict
		}
		if err := s.validate(); err != nil {
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
		var oldOverrides, nextOverrides generalCoreOverrides
		if old.General.CoreOverrides != nil {
			oldOverrides = *old.General.CoreOverrides
		}
		if s.CoreOverrides != nil {
			nextOverrides = *s.CoreOverrides
		}
		unifiedChanged := !sameBoolPtr(oldOverrides.UnifiedDelay, nextOverrides.UnifiedDelay)
		tcpChanged := !sameBoolPtr(oldOverrides.TCPConcurrent, nextOverrides.TCPConcurrent)
		ipv6Changed := !sameBoolPtr(oldOverrides.IPv6, nextOverrides.IPv6)
		loaderChanged := !sameStringPtr(oldOverrides.GeodataLoader, nextOverrides.GeodataLoader)
		liveGeneralChanged := hostsChanged || uaChanged || appendDNSChanged ||
			unifiedChanged || tcpChanged || ipv6Changed || loaderChanged

		rebuild := s.Ports == nil && old.General.Ports != nil ||
			s.Authentication == nil && old.General.Authentication != nil ||
			(liveGeneralChanged && !baseline.ready)
		if !rebuild && baseline.ready && baseline.dnsConfig != nil {
			nextIPv6 := baseline.effectiveIPv6(s)
			// 开启 IPv6 且原配置因禁用 IPv6 跳过了 fake-ip-range6 初始化时，走完整重建以交由内核校验 IPv6 环境。
			if ipv6Changed && nextIPv6 && baseline.dnsHasFakeIPRange6 && !baseline.dnsConfig.FakeIPRange6.IsValid() {
				rebuild = true
			}
			if ipv6Changed && !nextIPv6 && baseline.dnsConfig.EnhancedMode == C.DNSFakeIP && !baseline.dnsConfig.FakeIPRange.IsValid() {
				rebuild = true
			}
			if (appendDNSChanged || ipv6Changed) && baseline.dnsConfig.Enable && len(baseline.dnsServers(next.Profile, s.AppendSystemDNS)) == 0 {
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
				return errGeneralApply
			}
		} else {
			if s.Ports != nil {
				p := s.Ports
				b := &targetInbound.inbound
				b.MixedPort, b.Port, b.SocksPort, b.RedirPort, b.TProxyPort = p.Mixed, p.HTTP, p.SOCKS, p.Redir, p.TProxy
			}
			if hostsChanged {
				var err error
				nextHosts, err = buildMergedHosts(baseline.rawHosts, s.Hosts)
				if err != nil {
					return errGeneralApply
				}
			}
			dnsChanged := (appendDNSChanged && next.Profile != "" && !baseline.dnsAlreadyHasSystem) || ipv6Changed
			if dnsChanged && baseline.dnsConfig != nil {
				var err error
				nextDNS, err = buildLiveDNSConfig(baseline, next.Profile, s.AppendSystemDNS, baseline.effectiveIPv6(s))
				if err != nil {
					return errGeneralApply
				}
			}
		}
		if err := preflightGeneralPorts(targetInbound, s.ControllerSecret != ""); err != nil {
			return err
		}
		path := generalSettingsPath(old.HomeDir)
		staged, err := stageProfileSettings(path, s)
		if err != nil {
			return errGeneralIO
		}
		defer os.Remove(staged)
		if err := setPanelControllerLocked(s.ControllerSecret); err != nil {
			eng.publishRuntimeLocked()
			return errGeneralPanel
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
					mihomoHttp.SetUA(baseline.effectiveUA(s))
				}
				if unifiedChanged {
					adapter.UnifiedDelay.Store(baseline.effectiveUnifiedDelay(s))
				}
				if tcpChanged {
					dialer.SetTcpConcurrent(baseline.effectiveTCPConcurrent(s))
				}
				if loaderChanged {
					geodata.SetLoader(baseline.effectiveGeodataLoader(s))
				}
				if ipv6Changed {
					resolver.DisableIPv6 = !baseline.effectiveIPv6(s)
				}
				if hostsChanged {
					resolver.DefaultHosts = resolver.NewHosts(nextHosts)
				}
				if nextDNS != nil {
					applyLiveDNSLocked(nextDNS, baseline.effectiveIPv6(s), targetInbound)
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
				log.SetLevel(s.level())
				if !rebuild {
					tx.deferUnlock(eng.diag.SetCaptureLogs(s.CaptureLogs))
				}
				eng.publishRuntimeLocked()
				return nil
			}
			err = errGeneralIO
		} else {
			err = errGeneralPort
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
			err = errGeneralApply
		}
		eng.setCurrentLocked(old)
		log.SetLevel(old.General.level())
		return err
	})
}

func portsFromInbound(b config.Inbound) generalPorts {
	return generalPorts{b.MixedPort, b.Port, b.SocksPort, b.RedirPort, b.TProxyPort}
}

func preflightGeneralPorts(target inboundSettings, panel bool) error {
	b := target.inbound
	ports := portsFromInbound(b).values()
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
		if port == 19090 || panel && port == panelPort {
			return errGeneralPort
		}
		if eng.tun == nil || port == active.Port || port == active.SocksPort || port == active.RedirPort ||
			port == active.TProxyPort || port == active.MixedPort {
			continue
		}
		addr := net.JoinHostPort(address, strconv.Itoa(port))
		var lc net.ListenConfig
		socket, err := lc.Listen(context.Background(), "tcp", addr)
		if err != nil {
			return errGeneralPort
		}
		_ = socket.Close()
		if i == 0 || i == 2 || i == 4 {
			packet, err := lc.ListenPacket(context.Background(), "udp", addr)
			if err != nil {
				return errGeneralPort
			}
			_ = packet.Close()
		}
	}
	return nil
}

func applyGeneralListenersLocked(target inboundSettings, a *generalAuthentication) error {
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
	prior := generalPorts{old.MixedPort, old.Port, old.SocksPort, old.RedirPort, old.TProxyPort}.values()
	next := portsFromInbound(target.inbound).values()
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
	if (generalPorts{active.MixedPort, active.Port, active.SocksPort, active.RedirPort, active.TProxyPort}) != portsFromInbound(target.inbound) {
		return errGeneralPort
	}
	return nil
}
