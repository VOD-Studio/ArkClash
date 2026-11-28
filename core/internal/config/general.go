package config

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"os"
	"slices"
	"strings"
	"unicode"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/fakeip"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/trie"
	mihomoConfig "github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
)

type GeneralPorts struct {
	Mixed  int `json:"mixed"`
	HTTP   int `json:"http"`
	SOCKS  int `json:"socks"`
	Redir  int `json:"redir"`
	TProxy int `json:"tproxy"`
}

type GeneralAuthentication struct {
	Enabled  bool   `json:"enabled"`
	Username string `json:"username"`
	Password string `json:"password"`
}

// 内核可选覆写项；指针为 nil 表示未覆写，沿用配置或内核默认值。
type GeneralCoreOverrides struct {
	TestURL       *string `json:"testUrl,omitempty"`
	UnifiedDelay  *bool   `json:"unifiedDelay,omitempty"`
	TCPConcurrent *bool   `json:"tcpConcurrent,omitempty"`
	IPv6          *bool   `json:"ipv6,omitempty"`
	GeodataLoader *string `json:"geodataLoader,omitempty"`
}

type GeneralSettings struct {
	Revision         string                 `json:"revision"`
	Ports            *GeneralPorts          `json:"ports,omitempty"`
	Authentication   *GeneralAuthentication `json:"authentication,omitempty"`
	ControllerSecret string                 `json:"controllerSecret"`
	UserAgent        string                 `json:"userAgent"`
	UserAgents       []string               `json:"userAgents,omitempty"`
	AppendSystemDNS  bool                   `json:"appendSystemDns,omitempty"`
	Hosts            map[string][]string    `json:"hosts"`
	DelayTimeout     int                    `json:"delayTimeout"`
	CloseConnections *bool                  `json:"closeConnections,omitempty"`
	LogLevel         string                 `json:"logLevel"`
	CaptureLogs      bool                   `json:"captureLogs"`
	CoreOverrides    *GeneralCoreOverrides  `json:"coreOverrides,omitempty"`
}

const PanelPort = 9090

var (
	ErrGeneralInvalid  = errors.New("general_settings_invalid")
	ErrGeneralConflict = errors.New("general_settings_conflict")
	ErrGeneralIO       = errors.New("general_settings_io")
	ErrGeneralApply    = errors.New("general_settings_apply_failed")
	ErrGeneralPort     = errors.New("general_settings_port_busy")
	ErrGeneralPanel    = errors.New("general_settings_controller_busy")
)

func (p GeneralPorts) Values() [5]int {
	return [5]int{p.Mixed, p.HTTP, p.SOCKS, p.Redir, p.TProxy}
}

func (s GeneralSettings) Level() log.LogLevel {
	if level, ok := log.LogLevelMapping[s.LogLevel]; ok {
		return level
	}
	return log.ERROR
}

func validGeneralText(value string, limit int) bool {
	return len(value) <= limit && strings.TrimSpace(value) == value &&
		strings.IndexFunc(value, unicode.IsControl) == -1
}

func (s GeneralSettings) Validate() error {
	if !validGeneralText(s.Revision, 96) || s.Revision == "" || !validGeneralText(s.UserAgent, 512) {
		return ErrGeneralInvalid
	}
	if len(s.UserAgents) > 64 {
		return ErrGeneralInvalid
	}
	agents := make(map[string]bool, len(s.UserAgents))
	for _, agent := range s.UserAgents {
		if agent == "" || !validGeneralText(agent, 512) || agents[agent] {
			return ErrGeneralInvalid
		}
		agents[agent] = true
	}
	switch s.DelayTimeout {
	case 500, 1000, 2000, 5000, 8000:
	default:
		return ErrGeneralInvalid
	}
	if _, ok := log.LogLevelMapping[s.LogLevel]; !ok {
		return ErrGeneralInvalid
	}
	if s.ControllerSecret != "" && (!validGeneralText(s.ControllerSecret, 512) ||
		strings.ContainsAny(s.ControllerSecret, " \t")) {
		return ErrGeneralInvalid
	}
	if s.Ports != nil {
		seen := map[int]bool{19090: true}
		if s.ControllerSecret != "" {
			seen[PanelPort] = true
		}
		if s.Ports.Mixed == 0 {
			return ErrGeneralInvalid
		}
		for _, port := range s.Ports.Values() {
			if port == 0 {
				continue
			}
			if port < 1024 || port > 49151 || seen[port] {
				return ErrGeneralInvalid
			}
			seen[port] = true
		}
	}
	if a := s.Authentication; a != nil {
		if !validGeneralText(a.Username, 128) || !validGeneralText(a.Password, 512) ||
			strings.Contains(a.Username, ":") || (a.Enabled && (a.Username == "" || a.Password == "")) {
			return ErrGeneralInvalid
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

func validateGeneralCoreOverrides(overrides *GeneralCoreOverrides) error {
	if overrides == nil {
		return nil
	}
	if overrides.TestURL != nil && !validGeneralTestURL(*overrides.TestURL) {
		return ErrGeneralInvalid
	}
	if overrides.GeodataLoader != nil &&
		*overrides.GeodataLoader != "standard" && *overrides.GeodataLoader != "memconservative" {
		return ErrGeneralInvalid
	}
	return nil
}

func SameBoolPtr(left, right *bool) bool {
	if left == nil || right == nil {
		return left == right
	}
	return *left == *right
}

func SameStringPtr(left, right *string) bool {
	if left == nil || right == nil {
		return left == right
	}
	return *left == *right
}

func validateGeneralHosts(hosts map[string][]string) error {
	if len(hosts) > 256 {
		return ErrGeneralInvalid
	}
	keys := trie.New[struct{}]()
	domains := make(map[string]bool)
	aliases := make(map[string]string)
	for domain, values := range hosts {
		key := strings.ToLower(domain)
		if !validHostName(domain) || domains[key] || keys.Insert(domain, struct{}{}) != nil ||
			len(values) == 0 || len(values) > 32 {
			return ErrGeneralInvalid
		}
		domains[key] = true
		for _, value := range values {
			if addr, err := netip.ParseAddr(value); err == nil {
				if addr.Zone() != "" {
					return ErrGeneralInvalid
				}
			} else if !validHostName(value) {
				return ErrGeneralInvalid
			}
		}
		resolved, err := resolver.NewHostValue(values)
		if err != nil {
			return ErrGeneralInvalid
		}
		if resolved.IsDomain {
			aliases[key] = strings.ToLower(resolved.Domain)
		}
	}
	for domain := range aliases {
		seen := make(map[string]bool)
		for next := domain; next != ""; next = aliases[next] {
			if seen[next] {
				return ErrGeneralInvalid
			}
			seen[next] = true
		}
	}
	return nil
}

func validHostName(value string) bool {
	return value != "" && validGeneralText(value, 512) && !strings.ContainsAny(value, " /:?#@\t")
}

func GeneralSettingsPath(home string) string { return backup.DataPath(home, "general-settings.json") }

func ReadGeneralSettings(home string) (GeneralSettings, error) {
	file, err := os.Open(GeneralSettingsPath(home))
	if errors.Is(err, os.ErrNotExist) {
		return GeneralSettings{Revision: "default", DelayTimeout: 8000, LogLevel: "error"}, nil
	}
	if err != nil {
		return GeneralSettings{}, ErrGeneralIO
	}
	defer file.Close()
	var settings GeneralSettings
	if err := DecodeSettings(file, &settings); err != nil {
		return settings, ErrGeneralInvalid
	}
	return settings, settings.Validate()
}

func (s GeneralSettings) Apply(raw *mihomoConfig.RawConfig) {
	raw.LogLevel = s.Level()
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

// GeneralBaseline 记录当前生效配置在应用常规覆写前的基线，使请求与内核设置可原地热更新并恢复配置原值。
type GeneralBaseline struct {
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
	dnsConfig           *mihomoConfig.DNS
	dnsBaseServers      []dns.NameServer
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

func CaptureGeneralBaseline(rawCfg *mihomoConfig.RawConfig, opts StartOptions) GeneralBaseline {
	rawServers := rawCfg.DNS.NameServer
	if opts.Profile != "" && opts.DNS.Entries.Servers != nil {
		rawServers = *opts.DNS.Entries.Servers
	}
	return GeneralBaseline{
		globalUA:            rawCfg.GlobalUA,
		unifiedDelay:        rawCfg.UnifiedDelay,
		tcpConcurrent:       rawCfg.TCPConcurrent,
		ipv6:                rawCfg.IPv6,
		geodataLoader:       rawCfg.GeodataLoader,
		rawHosts:            cloneRawHosts(rawCfg.Hosts),
		storeFakeIP:         rawCfg.Profile.StoreFakeIP,
		dnsAlreadyHasSystem: HasSystemDNS(rawServers),
	}
}

func (b *GeneralBaseline) SetRawDNSFlags(respectRules, hasFakeIPRange6 bool) {
	b.dnsRespectRules = respectRules
	b.dnsHasFakeIPRange6 = hasFakeIPRange6
}

func (b GeneralBaseline) Ready() bool                  { return b.ready }
func (b GeneralBaseline) DNSConfig() *mihomoConfig.DNS { return b.dnsConfig }
func (b GeneralBaseline) RawHosts() map[string]any     { return b.rawHosts }
func (b GeneralBaseline) DNSAlreadyHasSystem() bool    { return b.dnsAlreadyHasSystem }
func (b GeneralBaseline) DNSHasFakeIPRange6() bool     { return b.dnsHasFakeIPRange6 }

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

func (b *GeneralBaseline) FinalizeDNS(parsed *mihomoConfig.DNS, appendedSystem bool) {
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

func (b GeneralBaseline) EffectiveUA(s GeneralSettings) string {
	if s.UserAgent != "" {
		return s.UserAgent
	}
	return b.globalUA
}

func (b GeneralBaseline) EffectiveUnifiedDelay(s GeneralSettings) bool {
	if s.CoreOverrides != nil && s.CoreOverrides.UnifiedDelay != nil {
		return *s.CoreOverrides.UnifiedDelay
	}
	return b.unifiedDelay
}

func (b GeneralBaseline) EffectiveTCPConcurrent(s GeneralSettings) bool {
	if s.CoreOverrides != nil && s.CoreOverrides.TCPConcurrent != nil {
		return *s.CoreOverrides.TCPConcurrent
	}
	return b.tcpConcurrent
}

func (b GeneralBaseline) EffectiveIPv6(s GeneralSettings) bool {
	if s.CoreOverrides != nil && s.CoreOverrides.IPv6 != nil {
		return *s.CoreOverrides.IPv6
	}
	return b.ipv6
}

func (b GeneralBaseline) EffectiveGeodataLoader(s GeneralSettings) string {
	if s.CoreOverrides != nil && s.CoreOverrides.GeodataLoader != nil {
		return *s.CoreOverrides.GeodataLoader
	}
	return b.geodataLoader
}

func (b GeneralBaseline) DNSServers(profile string, appendSystem bool) []dns.NameServer {
	servers := slices.Clone(b.dnsBaseServers)
	if profile != "" && appendSystem && !b.dnsAlreadyHasSystem && b.dnsConfig != nil {
		systemNS := systemDNSNameServer(b.dnsRespectRules, b.dnsConfig.PreferH3)
		if !slices.ContainsFunc(servers, systemNS.Equal) {
			servers = append(servers, systemNS)
		}
	}
	return servers
}

func BuildMergedHosts(base map[string]any, overrides map[string][]string) (*trie.DomainTrie[resolver.HostValue], error) {
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

func BuildLiveDNSConfig(base GeneralBaseline, profile string, appendSystem, effectiveIPv6 bool) (*mihomoConfig.DNS, error) {
	if base.dnsConfig == nil {
		return nil, nil
	}
	dnsCfg := *base.dnsConfig
	dnsCfg.NameServer = base.DNSServers(profile, appendSystem)
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
