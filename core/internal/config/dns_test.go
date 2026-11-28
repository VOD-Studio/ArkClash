package config

import (
	"errors"
	"slices"
	"testing"

	"github.com/VOD-Studio/ArkClash/core/internal/geo"
	mihomoConfig "github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
)

func TestAppendSystemDNSPreservesEffectiveUpstream(t *testing.T) {
	for _, tc := range []struct {
		configured []string
		want       []string
	}{
		{[]string{"tls://1.1.1.1"}, []string{"tls://1.1.1.1", "system://"}},
		{[]string{"9.9.9.9", "dhcp://system"}, []string{"9.9.9.9", "dhcp://system"}},
		{[]string{"9.9.9.9", "system://#DIRECT"}, []string{"9.9.9.9", "system://#DIRECT"}},
	} {
		raw := mihomoConfig.DefaultRawConfig()
		raw.DNS.NameServer = []string{"8.8.8.8"}
		opts := StartOptions{Profile: "test", General: GeneralSettings{AppendSystemDNS: true},
			DNS: DNSOverrideSettings{Entries: DNSOverrideEntries{Servers: &tc.configured}}}
		ApplyOverrides(raw, opts)
		if !slices.Equal(raw.DNS.NameServer, tc.want) {
			t.Fatalf("enabled with %v: got %v want %v", tc.configured, raw.DNS.NameServer, tc.want)
		}
		opts.General.AppendSystemDNS = false
		ApplyOverrides(raw, opts)
		if !slices.Equal(raw.DNS.NameServer, tc.configured) {
			t.Fatalf("disabled with %v: got %v", tc.configured, raw.DNS.NameServer)
		}
	}
}

func TestDNSOverridesOnlyReplaceAddedFields(t *testing.T) {
	raw := mihomoConfig.DefaultRawConfig()
	raw.DNS.Enable = false
	raw.DNS.IPv6 = true
	raw.DNS.Fallback = []string{"9.9.9.9"}
	raw.DNS.UseHosts = true
	settings := DNSOverrideSettings{Revision: "example", Entries: DNSOverrideEntries{
		IPv6: new(false), Fallback: new([]string{}), EnhancedMode: new(constant.DNSMapping),
	}}
	ApplyOverrides(raw, StartOptions{Profile: "a", DNS: settings, Geo: geo.DefaultSettings()})
	if !raw.DNS.Enable || raw.DNS.IPv6 || len(raw.DNS.Fallback) != 0 || !raw.DNS.UseHosts ||
		raw.DNS.EnhancedMode != constant.DNSMapping {
		t.Fatal("DNS merge changed inherited fields or dropped explicit false and empty values")
	}
}

func TestDNSExtraOverridesKeepPolicyOrderAndUnsetFallbackFields(t *testing.T) {
	raw := mihomoConfig.DefaultRawConfig()
	raw.DNS.FallbackFilter.GeoIPCode = "US"
	raw.DNS.FallbackFilter.Domain = []string{"+.example.test"}
	settings := DNSOverrideSettings{Revision: "sample", Entries: DNSOverrideEntries{
		IPv6Timeout: new(uint(10)), UseSystemHosts: new(false), CacheAlgorithm: new("arc"),
		CacheMaxSize: new(0), FakeIPRange: new("198.19.0.1/16"), FakeIPRange6: new("fd00::1/64"),
		FakeIPTTL: new(23), Policy: new([]DNSPolicyRow{
			{Pattern: "+.example.test", Servers: []string{"1.1.1.1", "8.8.8.8"}},
			{Pattern: "test.example", Servers: []string{"9.9.9.9"}},
		}),
		FallbackGeoIP: new(false), FallbackIPCIDR: new([]string{"192.0.2.0/24"}),
		DirectFollowPolicy: new(true),
	}}
	if err := settings.Validate(); err != nil {
		t.Fatal(err)
	}
	settings.Entries.Apply(&raw.DNS)
	first := raw.DNS.NameServerPolicy.Oldest()
	if first == nil || first.Key != "+.example.test" || len(first.Value.([]string)) != 2 ||
		first.Next() == nil || first.Next().Key != "test.example" {
		t.Fatal("DNS policy rows lost their order or servers")
	}
	if raw.DNS.FallbackFilter.GeoIP || raw.DNS.FallbackFilter.GeoIPCode != "US" ||
		len(raw.DNS.FallbackFilter.Domain) != 1 || len(raw.DNS.FallbackFilter.IPCIDR) != 1 ||
		raw.DNS.UseSystemHosts || raw.DNS.FakeIPTTL != 23 || raw.DNS.CacheAlgorithm != "arc" ||
		raw.DNS.CacheMaxSize != 0 || !raw.DNS.DirectNameServerFollowPolicy {
		t.Fatal("DNS settings lost an explicit value or replaced inherited fields")
	}
	settings.Entries.Policy = new([]DNSPolicyRow{})
	settings.Entries.Apply(&raw.DNS)
	if raw.DNS.NameServerPolicy.Len() != 0 {
		t.Fatal("an explicit empty policy must clear the profile policy")
	}
	settings.Entries.FakeIPRange6 = new("192.0.2.0/24")
	if !errors.Is(settings.Validate(), ErrDNSInvalid) {
		t.Fatal("IPv4 prefix accepted in the IPv6 field")
	}
}
