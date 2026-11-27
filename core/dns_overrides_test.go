package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
)

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
	next := corecfg.DNSOverrideRequest{BootID: bootID, ExpectedRevision: "default", Settings: corecfg.DNSOverrideSettings{
		Revision: "occupied", Entries: corecfg.DNSOverrideEntries{Listen: &address},
	}}
	if err := updateDNSOverrides(next); !errors.Is(err, corecfg.ErrDNSListen) {
		t.Fatalf("expected bind conflict, got %v", err)
	}
	if eng.current.DNS.Revision != "default" || eng.tun != originalTun || resolver.DefaultService != originalResolver {
		t.Fatal("failed validation changed the active DNS configuration or TUN")
	}

	if err := occupied.Close(); err != nil {
		t.Fatal(err)
	}
	path := corecfg.DNSOverridesPath(opts.HomeDir)
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	next.Settings.Revision = "unwritable"
	if err := updateDNSOverrides(next); !errors.Is(err, corecfg.ErrDNSIO) {
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
	if err := updateDNSOverrides(next); !errors.Is(err, corecfg.ErrDNSProxyServersRequired) || eng.current.DNS.Revision != "default" || eng.tun != originalTun {
		t.Fatalf("missing proxy DNS did not preserve the running configuration: %v", err)
	}
	next.Settings.Revision = "committed"
	next.Settings.Entries.EnhancedMode = new(constant.DNSFakeIP)
	next.Settings.Entries.CacheAlgorithm = new("arc")
	next.Settings.Entries.CacheMaxSize = new(128)
	next.Settings.Entries.FakeIPRange = new("198.19.0.1/16")
	next.Settings.Entries.FakeIPTTL = new(5)
	next.Settings.Entries.Policy = new([]corecfg.DNSPolicyRow{{Pattern: "+.example.test", Servers: []string{"1.1.1.1"}}})
	next.Settings.Entries.ProxyServers = new([]string{"9.9.9.9"})
	next.Settings.Entries.RespectRules = new(true)
	if err := updateDNSOverrides(next); err != nil {
		t.Fatal(err)
	}
	tcp, udp = dns.ArkClashServerSnapshot()
	saved, err := corecfg.ReadDNSOverrides(opts.HomeDir)
	if err != nil || saved.Revision != "committed" || eng.current.ConfigPath != formal || tcp != address || udp != address || eng.tun !=
		originalTun || resolver.DefaultService == originalResolver || eng.Status().BootID != bootID {
		t.Fatalf("live apply did not replace the resolver and persist the same settings: %v", err)
	}
	if err := updateDNSOverrides(next); !errors.Is(err, corecfg.ErrDNSConflict) {
		t.Fatalf("stale revision did not conflict: %v", err)
	}
	next.ExpectedRevision = "committed"
	next.Settings = corecfg.DNSOverrideSettings{Revision: "removed"}
	if err := updateDNSOverrides(next); err != nil {
		t.Fatal(err)
	}
	tcp, udp = dns.ArkClashServerSnapshot()
	if tcp != "" || udp != "" || eng.tun != originalTun {
		t.Fatal("removing the override did not restore the profile's listener setting")
	}
}
