package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
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
		raw := config.DefaultRawConfig()
		raw.DNS.NameServer = []string{"8.8.8.8"}
		opts := startOptions{Profile: "test", General: generalSettings{AppendSystemDNS: true},
			DNS: dnsOverrideSettings{Entries: dnsOverrideEntries{Servers: &tc.configured}}}
		applyOverrides(raw, opts)
		if !slices.Equal(raw.DNS.NameServer, tc.want) {
			t.Fatalf("enabled with %v: got %v want %v", tc.configured, raw.DNS.NameServer, tc.want)
		}
		opts.General.AppendSystemDNS = false
		applyOverrides(raw, opts)
		if !slices.Equal(raw.DNS.NameServer, tc.configured) {
			t.Fatalf("disabled with %v: got %v", tc.configured, raw.DNS.NameServer)
		}
	}
}

func TestDNSOverridesOnlyReplaceAddedFields(t *testing.T) {
	raw := config.DefaultRawConfig()
	raw.DNS.Enable = false
	raw.DNS.IPv6 = true
	raw.DNS.Fallback = []string{"9.9.9.9"}
	raw.DNS.UseHosts = true
	settings := dnsOverrideSettings{Revision: "example", Entries: dnsOverrideEntries{
		IPv6: new(false), Fallback: new([]string{}), EnhancedMode: new(constant.DNSMapping),
	}}
	applyOverrides(raw, startOptions{Profile: "a", DNS: settings, Geo: defaultGeoSettings()})
	if !raw.DNS.Enable || raw.DNS.IPv6 || len(raw.DNS.Fallback) != 0 || !raw.DNS.UseHosts ||
		raw.DNS.EnhancedMode != constant.DNSMapping {
		t.Fatal("DNS merge changed inherited fields or dropped explicit false and empty values")
	}
}

func TestDNSExtraOverridesKeepPolicyOrderAndUnsetFallbackFields(t *testing.T) {
	raw := config.DefaultRawConfig()
	raw.DNS.FallbackFilter.GeoIPCode = "US"
	raw.DNS.FallbackFilter.Domain = []string{"+.example.test"}
	settings := dnsOverrideSettings{Revision: "sample", Entries: dnsOverrideEntries{
		IPv6Timeout: new(uint(10)), UseSystemHosts: new(false), CacheAlgorithm: new("arc"),
		CacheMaxSize: new(0), FakeIPRange: new("198.19.0.1/16"), FakeIPRange6: new("fd00::1/64"),
		FakeIPTTL: new(23), Policy: new([]dnsPolicyRow{
			{Pattern: "+.example.test", Servers: []string{"1.1.1.1", "8.8.8.8"}},
			{Pattern: "test.example", Servers: []string{"9.9.9.9"}},
		}),
		FallbackGeoIP: new(false), FallbackIPCIDR: new([]string{"192.0.2.0/24"}),
		DirectFollowPolicy: new(true),
	}}
	if err := settings.validate(); err != nil {
		t.Fatal(err)
	}
	settings.Entries.apply(&raw.DNS)
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
	settings.Entries.Policy = new([]dnsPolicyRow{})
	settings.Entries.apply(&raw.DNS)
	if raw.DNS.NameServerPolicy.Len() != 0 {
		t.Fatal("an explicit empty policy must clear the profile policy")
	}
	settings.Entries.FakeIPRange6 = new("192.0.2.0/24")
	if !errors.Is(settings.validate(), errDNSInvalid) {
		t.Fatal("IPv4 prefix accepted in the IPv6 field")
	}
}

func TestDNSOverridesLiveApplyAndBindConflictPreserveTun(t *testing.T) {
	opts := lifecycleOptions(t)
	opts.Profile = "dns"
	formal := lifecycleWriteProfile(t, opts, opts.Profile, lifecycleProfile+"\ndns:\n  enable: true\n  nameserver: [1.1.1.1]\n")
	opts.ConfigPath = filepath.Join(opts.HomeDir, "profiles", ".candidate.yaml")
	if err := os.Rename(formal, opts.ConfigPath); err != nil {
		t.Fatal(err)
	}
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	if err := os.Rename(opts.ConfigPath, formal); err != nil {
		t.Fatal(err)
	}
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	originalTun := eng.tun
	originalResolver := resolver.DefaultService
	bootID := eng.Status().BootID

	occupied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	address := occupied.Addr().String()
	next := dnsOverrideRequest{BootID: bootID, ExpectedRevision: "default", Settings: dnsOverrideSettings{
		Revision: "occupied", Entries: dnsOverrideEntries{Listen: &address},
	}}
	if err := updateDNSOverrides(next); !errors.Is(err, errDNSListen) {
		t.Fatalf("expected bind conflict, got %v", err)
	}
	if eng.current.DNS.Revision != "default" || eng.tun != originalTun || resolver.DefaultService != originalResolver {
		t.Fatal("failed validation changed the active DNS configuration or TUN")
	}

	if err := occupied.Close(); err != nil {
		t.Fatal(err)
	}
	path := dnsOverridesPath(opts.HomeDir)
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	next.Settings.Revision = "unwritable"
	if err := updateDNSOverrides(next); !errors.Is(err, errDNSIO) {
		t.Fatalf("expected persistence failure, got %v", err)
	}
	tcp, udp := dns.ArkClashServerSnapshot()
	if eng.current.DNS.Revision != "default" || tcp != "" || udp != "" || eng.tun != originalTun {
		t.Fatal("persistence failure left the candidate DNS override active")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	next.Settings.Revision = "missing-proxy-dns"
	next.Settings.Entries.RespectRules = new(true)
	if err := updateDNSOverrides(next); !errors.Is(err, errDNSProxyServersRequired) || eng.current.DNS.Revision != "default" || eng.tun != originalTun {
		t.Fatalf("missing proxy DNS did not preserve the running configuration: %v", err)
	}
	next.Settings.Revision = "committed"
	next.Settings.Entries.EnhancedMode = new(constant.DNSFakeIP)
	next.Settings.Entries.CacheAlgorithm = new("arc")
	next.Settings.Entries.CacheMaxSize = new(128)
	next.Settings.Entries.FakeIPRange = new("198.19.0.1/16")
	next.Settings.Entries.FakeIPTTL = new(5)
	next.Settings.Entries.Policy = new([]dnsPolicyRow{{Pattern: "+.example.test", Servers: []string{"1.1.1.1"}}})
	next.Settings.Entries.ProxyServers = new([]string{"9.9.9.9"})
	next.Settings.Entries.RespectRules = new(true)
	if err := updateDNSOverrides(next); err != nil {
		t.Fatal(err)
	}
	tcp, udp = dns.ArkClashServerSnapshot()
	saved, err := readDNSOverrides(opts.HomeDir)
	if err != nil || saved.Revision != "committed" || eng.current.ConfigPath != formal || tcp != address || udp != address || eng.tun !=
		originalTun || resolver.DefaultService == originalResolver || eng.Status().BootID != bootID {
		t.Fatalf("live apply did not replace the resolver and persist the same settings: %v", err)
	}
	if err := updateDNSOverrides(next); !errors.Is(err, errDNSConflict) {
		t.Fatalf("stale revision did not conflict: %v", err)
	}
	next.ExpectedRevision = "committed"
	next.Settings = dnsOverrideSettings{Revision: "removed"}
	if err := updateDNSOverrides(next); err != nil {
		t.Fatal(err)
	}
	tcp, udp = dns.ArkClashServerSnapshot()
	if tcp != "" || udp != "" || eng.tun != originalTun {
		t.Fatal("removing the override did not restore the profile's listener setting")
	}
}
