package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/common/orderedmap"
	"github.com/metacubex/mihomo/component/trie"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
)

type dnsOverrideSettings struct {
	Revision string             `json:"revision"`
	Entries  dnsOverrideEntries `json:"entries"`
}

type dnsOverrideEntries struct {
	Listen             *string              `json:"listen,omitempty"`
	IPv6               *bool                `json:"ipv6,omitempty"`
	IPv6Timeout        *uint                `json:"ipv6-timeout,omitempty"`
	UseHosts           *bool                `json:"use-hosts,omitempty"`
	UseSystemHosts     *bool                `json:"use-system-hosts,omitempty"`
	RespectRules       *bool                `json:"respect-rules,omitempty"`
	PreferH3           *bool                `json:"prefer-h3,omitempty"`
	CacheAlgorithm     *string              `json:"cache-algorithm,omitempty"`
	CacheMaxSize       *int                 `json:"cache-max-size,omitempty"`
	EnhancedMode       *constant.DNSMode    `json:"enhanced-mode,omitempty"`
	FakeIPRange        *string              `json:"fake-ip-range,omitempty"`
	FakeIPRange6       *string              `json:"fake-ip-range6,omitempty"`
	FakeIPTTL          *int                 `json:"fake-ip-ttl,omitempty"`
	FakeIPFilter       *[]string            `json:"fake-ip-filter,omitempty"`
	FakeIPMode         *constant.FilterMode `json:"fake-ip-filter-mode,omitempty"`
	DefaultServers     *[]string            `json:"default-nameserver,omitempty"`
	Servers            *[]string            `json:"nameserver,omitempty"`
	Policy             *[]dnsPolicyRow      `json:"nameserver-policy,omitempty"`
	Fallback           *[]string            `json:"fallback,omitempty"`
	FallbackLazyQuery  *bool                `json:"fallback-lazy-query,omitempty"`
	FallbackGeoIP      *bool                `json:"fallback-filter.geoip,omitempty"`
	FallbackGeoIPCode  *string              `json:"fallback-filter.geoip-code,omitempty"`
	FallbackGeoSite    *[]string            `json:"fallback-filter.geosite,omitempty"`
	FallbackIPCIDR     *[]string            `json:"fallback-filter.ipcidr,omitempty"`
	FallbackDomain     *[]string            `json:"fallback-filter.domain,omitempty"`
	ProxyServers       *[]string            `json:"proxy-server-nameserver,omitempty"`
	ProxyPolicy        *[]dnsPolicyRow      `json:"proxy-server-nameserver-policy,omitempty"`
	DirectServers      *[]string            `json:"direct-nameserver,omitempty"`
	DirectFollowPolicy *bool                `json:"direct-nameserver-follow-policy,omitempty"`
}

type dnsPolicyRow struct {
	Pattern string   `json:"pattern"`
	Servers []string `json:"servers"`
}

func replaceDNSPolicy(field **orderedmap.OrderedMap[string, any], rows *[]dnsPolicyRow) {
	if rows == nil {
		return
	}
	policy := orderedmap.New[string, any]()
	for _, row := range *rows {
		policy.Set(row.Pattern, row.Servers)
	}
	*field = policy
}

func replaceDNSField[T any](field *T, override *T) {
	if override != nil {
		*field = *override
	}
}

func (e dnsOverrideEntries) apply(raw *config.RawDNS) {
	replaceDNSField(&raw.Listen, e.Listen)
	replaceDNSField(&raw.IPv6, e.IPv6)
	replaceDNSField(&raw.IPv6Timeout, e.IPv6Timeout)
	replaceDNSField(&raw.UseHosts, e.UseHosts)
	replaceDNSField(&raw.UseSystemHosts, e.UseSystemHosts)
	replaceDNSField(&raw.RespectRules, e.RespectRules)
	replaceDNSField(&raw.PreferH3, e.PreferH3)
	replaceDNSField(&raw.CacheAlgorithm, e.CacheAlgorithm)
	replaceDNSField(&raw.CacheMaxSize, e.CacheMaxSize)
	replaceDNSField(&raw.EnhancedMode, e.EnhancedMode)
	replaceDNSField(&raw.FakeIPRange, e.FakeIPRange)
	replaceDNSField(&raw.FakeIPRange6, e.FakeIPRange6)
	replaceDNSField(&raw.FakeIPTTL, e.FakeIPTTL)
	replaceDNSField(&raw.FakeIPFilter, e.FakeIPFilter)
	replaceDNSField(&raw.FakeIPFilterMode, e.FakeIPMode)
	replaceDNSField(&raw.DefaultNameserver, e.DefaultServers)
	replaceDNSField(&raw.NameServer, e.Servers)
	replaceDNSPolicy(&raw.NameServerPolicy, e.Policy)
	replaceDNSField(&raw.Fallback, e.Fallback)
	replaceDNSField(&raw.FallbackLazyQuery, e.FallbackLazyQuery)
	replaceDNSField(&raw.FallbackFilter.GeoIP, e.FallbackGeoIP)
	replaceDNSField(&raw.FallbackFilter.GeoIPCode, e.FallbackGeoIPCode)
	replaceDNSField(&raw.FallbackFilter.GeoSite, e.FallbackGeoSite)
	replaceDNSField(&raw.FallbackFilter.IPCIDR, e.FallbackIPCIDR)
	replaceDNSField(&raw.FallbackFilter.Domain, e.FallbackDomain)
	replaceDNSField(&raw.ProxyServerNameserver, e.ProxyServers)
	replaceDNSPolicy(&raw.ProxyServerNameserverPolicy, e.ProxyPolicy)
	replaceDNSField(&raw.DirectNameServer, e.DirectServers)
	replaceDNSField(&raw.DirectNameServerFollowPolicy, e.DirectFollowPolicy)
}

func hasSystemDNS(servers []string) bool {
	for _, server := range servers {
		if server == "system" || server == "dhcp://system" {
			return true
		}
		if parsed, err := url.Parse(server); err == nil && parsed.Scheme == "system" {
			return true
		}
	}
	return false
}

func appendSystemDNS(raw *config.RawDNS) {
	if hasSystemDNS(raw.NameServer) {
		return
	}
	raw.NameServer = append(raw.NameServer, "system://")
}

var (
	errDNSInvalid              = errors.New("dns_override_invalid")
	errDNSConflict             = errors.New("dns_override_conflict")
	errDNSIO                   = errors.New("dns_override_io")
	errDNSApply                = errors.New("dns_override_apply_failed")
	errDNSListen               = errors.New("dns_override_listen_failed")
	errDNSProxyServersRequired = errors.New("dns_override_proxy_servers_required")
)

func (e dnsOverrideEntries) missingProxyServers(raw *config.RawDNS) bool {
	return (e.RespectRules != nil || e.ProxyPolicy != nil || e.ProxyServers != nil) &&
		len(raw.ProxyServerNameserver) == 0 && (raw.RespectRules || raw.ProxyServerNameserverPolicy.Len() > 0)
}

func (s dnsOverrideSettings) validate() error {
	const maxNumber = 1<<31 - 1
	e := s.Entries
	if len(s.Revision) == 0 || len(s.Revision) > 80 ||
		(e.EnhancedMode != nil && *e.EnhancedMode == constant.DNSHosts) ||
		(e.DefaultServers != nil && len(*e.DefaultServers) == 0) || (e.Servers != nil && len(*e.Servers) == 0) {
		return errDNSInvalid
	}
	if (e.CacheAlgorithm != nil && *e.CacheAlgorithm != "lru" && *e.CacheAlgorithm != "arc") ||
		(e.CacheMaxSize != nil && (*e.CacheMaxSize < 0 || *e.CacheMaxSize > maxNumber)) ||
		(e.FakeIPTTL != nil && (*e.FakeIPTTL < 0 || *e.FakeIPTTL > maxNumber)) ||
		(e.IPv6Timeout != nil && *e.IPv6Timeout > maxNumber) ||
		(e.FallbackGeoIPCode != nil && !validDNSItem(*e.FallbackGeoIPCode, 64)) ||
		!validFakeIPRange(e.FakeIPRange, false) || !validFakeIPRange(e.FakeIPRange6, true) ||
		!validDNSPolicy(e.Policy) || !validDNSPolicy(e.ProxyPolicy) {
		return errDNSInvalid
	}
	if e.Listen != nil && *e.Listen != "" {
		_, port, err := net.SplitHostPort(*e.Listen)
		value, parseErr := strconv.ParseUint(port, 10, 16)
		if err != nil || parseErr != nil || value == 0 || len(*e.Listen) > 320 {
			return errDNSInvalid
		}
	}
	for _, list := range []*[]string{e.DefaultServers, e.Servers, e.Fallback, e.ProxyServers, e.DirectServers} {
		if list != nil && !validDNSList(*list, true) {
			return errDNSInvalid
		}
	}
	for _, list := range []*[]string{e.FakeIPFilter, e.FallbackGeoSite, e.FallbackIPCIDR, e.FallbackDomain} {
		if list != nil && !validDNSList(*list, false) {
			return errDNSInvalid
		}
	}
	if e.FallbackIPCIDR != nil {
		for _, value := range *e.FallbackIPCIDR {
			if _, err := netip.ParsePrefix(value); err != nil {
				return errDNSInvalid
			}
		}
	}
	if e.FallbackDomain != nil {
		for _, value := range *e.FallbackDomain {
			if _, err := trie.ValidAndSplitDomain(value); err != nil {
				return errDNSInvalid
			}
		}
	}
	return nil
}

func validDNSItem(item string, limit int) bool {
	return item != "" && len(item) <= limit && strings.TrimSpace(item) == item && !strings.ContainsAny(item, "\x00\r\n")
}

func validDNSList(list []string, servers bool) bool {
	if len(list) > 256 {
		return false
	}
	for _, item := range list {
		if !validDNSItem(item, 2048) {
			return false
		}
	}
	if servers {
		_, err := dns.ParseNameServer(list)
		return err == nil
	}
	return true
}

func validDNSPolicy(rows *[]dnsPolicyRow) bool {
	if rows == nil {
		return true
	}
	if len(*rows) > 256 {
		return false
	}
	seen := make(map[string]bool, len(*rows))
	for _, row := range *rows {
		if !validDNSItem(row.Pattern, 2048) || seen[row.Pattern] || len(row.Servers) == 0 ||
			!validDNSList(row.Servers, true) {
			return false
		}
		seen[row.Pattern] = true
	}
	return true
}

func validFakeIPRange(value *string, ipv6 bool) bool {
	if value == nil || *value == "" {
		return true
	}
	prefix, err := netip.ParsePrefix(*value)
	// 池需要网络地址、网关和若干保留地址，至少要有三个主机位。
	return err == nil && prefix.Addr().Is6() == ipv6 && !prefix.Addr().Is4In6() &&
		prefix.Addr().BitLen()-prefix.Bits() >= 3
}

func dnsOverridesPath(home string) string {
	return portableDataPath(home, "dns-overrides.json")
}

func readDNSOverrides(home string) (dnsOverrideSettings, error) {
	file, err := os.Open(dnsOverridesPath(home))
	if errors.Is(err, os.ErrNotExist) {
		return dnsOverrideSettings{Revision: "default"}, nil
	}
	if err != nil {
		return dnsOverrideSettings{}, errDNSIO
	}
	defer file.Close()
	var settings dnsOverrideSettings
	if err := decodeProfileSettings(file, &settings); err != nil {
		return settings, errDNSInvalid
	}
	return settings, settings.validate()
}

type dnsOverrideRequest = profileSettingsRequest[dnsOverrideSettings]

func postDNSOverrides(w http.ResponseWriter, r *http.Request) {
	var request dnsOverrideRequest
	if err := decodeProfileSettings(r.Body, &request); err != nil {
		writeError(w, r, http.StatusBadRequest, errDNSInvalid)
		return
	}
	if err := updateDNSOverrides(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errDNSConflict) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func updateDNSOverrides(request dnsOverrideRequest) error {
	return eng.withState(func(tx *stateTx) error {
		if !profileSettingsCurrent(request.BootID, request.ExpectedRevision, eng.current.DNS.Revision, request.Settings.Revision) {
			return errDNSConflict
		}
		if err := request.Settings.validate(); err != nil {
			return err
		}
		next := eng.current
		next.DNS = request.Settings
		wait, err := applyProfileSettingsLocked(next, dnsOverridesPath(next.HomeDir), next.DNS)
		tx.deferUnlock(wait)
		switch err {
		case nil:
			return nil
		case errProfileSettingsInvalid:
			return errDNSInvalid
		case errProfileSettingsIO:
			return errDNSIO
		case errProfileSettingsListen:
			return errDNSListen
		case errDNSProxyServersRequired:
			return errDNSProxyServersRequired
		default:
			return errDNSApply
		}
	})
}

func dnsListenerAvailable(address string, mark int) bool {
	if address == "" || address == eng.desiredInbound.dnsListen {
		return true
	}
	lc := inbound.NewListenConfig()
	lc.SetRouteMark(mark)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	tcp, err := lc.Listen(ctx, "tcp", address)
	if err != nil {
		return false
	}
	defer tcp.Close()
	udp, err := lc.ListenPacket(ctx, "udp", address)
	if err != nil {
		return false
	}
	return udp.Close() == nil
}
