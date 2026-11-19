package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
)

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
	originalTun := tunListener
	originalResolver := resolver.DefaultService
	bootID := runtimeSnapshot.Load().BootID

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
	if current.DNS.Revision != "default" || tunListener != originalTun || resolver.DefaultService != originalResolver {
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
	if current.DNS.Revision != "default" || tcp != "" || udp != "" || tunListener != originalTun {
		t.Fatal("persistence failure left the candidate DNS override active")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	next.Settings.Revision = "committed"
	next.Settings.Entries.EnhancedMode = new(constant.DNSFakeIP)
	if err := updateDNSOverrides(next); err != nil {
		t.Fatal(err)
	}
	tcp, udp = dns.ArkClashServerSnapshot()
	saved, err := readDNSOverrides(opts.HomeDir)
	if err != nil || saved.Revision != "committed" || current.ConfigPath != formal || tcp != address || udp != address ||
		tunListener != originalTun || resolver.DefaultService == originalResolver || runtimeSnapshot.Load().BootID != bootID {
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
	if tcp != "" || udp != "" || tunListener != originalTun {
		t.Fatal("removing the override did not restore the profile's listener setting")
	}
}
