package main

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
)

const lifecycleProfile = `mode: direct
log-level: silent
proxy-groups:
  - name: Manual
    type: select
    proxies: [DIRECT, REJECT]
rules: ['MATCH,DIRECT']
`

func lifecycleOptions(t *testing.T) startOptions {
	t.Helper()
	home := t.TempDir()
	if err := os.Mkdir(filepath.Join(home, "profiles"), 0700); err != nil {
		t.Fatal(err)
	}
	reserved, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := reserved.Addr().String()
	if err := reserved.Close(); err != nil {
		t.Fatal(err)
	}
	return startOptions{HomeDir: home, Controller: address, Geo: defaultGeoSettings()}
}

func lifecycleController(t *testing.T, address string, wantOpen bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		connection, err := net.DialTimeout("tcp", address, 50*time.Millisecond)
		if connection != nil {
			connection.Close()
		}
		if (err == nil) == wantOpen {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("controller open=%v, want %v: %v", err == nil, wantOpen, err)
		}
		time.Sleep(time.Millisecond)
	}
}

func lifecycleVpnState(t *testing.T, intent, forward string, created bool) {
	t.Helper()
	mu.Lock()
	err := updateVpnState(intent, forward, created)
	mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
}

func lifecycleWriteProfile(t *testing.T, options startOptions, name, content string) string {
	t.Helper()
	path := filepath.Join(options.HomeDir, "profiles", name+".yaml")
	if err := os.WriteFile(path, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func hostAttachIdentity() attachIdentity {
	state := runtimeSnapshot.Load()
	if state == nil {
		return attachIdentity{}
	}
	return attachIdentity{BootID: state.BootID, Profile: state.Profile, ConfigRevision: state.ConfigRevision}
}


func TestLifecycleWarmReloadAttachDetachPreservesCore(t *testing.T) {
	options := lifecycleOptions(t)
	// 空内核不能把空编号当成一份配置，更不能恢复它的选择文件。
	if err := os.WriteFile(selectionPath(options.HomeDir, ""), []byte("invalid JSON"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := start(options); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		hostTunStartError = nil
		hostTunStopError = nil
		stop()
		lifecycleVpnState(t, "stopped", "stopped", false)
		lifecycleController(t, options.Controller, false)
	})
	lifecycleController(t, options.Controller, true)
	warm := *runtimeSnapshot.Load()
	if !warm.Running || warm.Profile != "" || warm.TunAttached || warm.VpnCreated || warm.ListenersOpen ||
		warm.Intent != "stopped" || warm.Forward != "stopped" || warm.StartedAt != 0 || warm.BootID == "" {
		t.Fatalf("invalid warm state: %+v", warm)
	}
	if profile, online := runningProfile(); profile != "" || !online {
		t.Fatalf("empty warm core is not online: %q %v", profile, online)
	}
	if _, err := os.Stat(filepath.Join(options.HomeDir, "config.yaml")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("warm start created a fake configuration: %v", err)
	}
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err == nil {
		t.Fatal("empty core accepted a TUN")
	}
	if err := start(options); err == nil {
		t.Fatal("second start replaced a live core")
	}

	path := lifecycleWriteProfile(t, options, "one", lifecycleProfile)
	if err := saveSelections(options.HomeDir, "one", map[string]string{"Manual": "REJECT"}); err != nil {
		t.Fatal(err)
	}
	if err := reload(path, "one", new("")); err != nil {
		t.Fatal(err)
	}
	loaded := *runtimeSnapshot.Load()
	if loaded.BootID != warm.BootID || loaded.ConfigRevision != warm.ConfigRevision+1 || loaded.Profile != "one" || loaded.TunAttached {
		t.Fatalf("first profile did not activate warm core: %+v", loaded)
	}
	before, err := captureProxySnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if before.Actual["Manual"] != before.Proxies["REJECT"].ID {
		t.Fatal("selected profile did not restore its own choice")
	}
	mapper := resolver.DefaultHostMapper
	if mapper == nil {
		t.Fatal("warm core has no fake-IP mapper")
	}
	if err := attachTun(0, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err == nil {
		t.Fatal("invalid TUN fd accepted")
	}
	attachFailure := errors.New("fixture attach failure")
	hostTunStartError = attachFailure
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); !errors.Is(err, attachFailure) || tunListener != nil {
		t.Fatalf("failed attach changed resource facts: %v", err)
	}
	hostTunStartError = nil

	mode, allowLan := "global", true
	if err := setRuntimeOptions(&mode, &allowLan); err != nil {
		t.Fatal(err)
	}
	lifecycleVpnState(t, "started", "preparing", true)
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	attached := tunListener
	if attached == nil {
		t.Fatal("successful attach did not publish a TUN")
	}
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil || tunListener != attached {
		t.Fatal("duplicate attach rebuilt the TUN")
	}
	lifecycleVpnState(t, "started", "running", true)
	if state := runtimeSnapshot.Load(); !state.TunAttached || !state.VpnCreated || state.Forward != "running" || state.StartedAt == 0 {
		t.Fatalf("attached state is not forwarding: %+v", state)
	}

	if err := detachTun(); err != nil {
		t.Fatal(err)
	}
	pending := runtimeSnapshot.Load()
	if pending.TunAttached || !pending.VpnCreated || pending.Forward == "stopped" {
		t.Fatalf("detach hid the platform VPN resource: %+v", pending)
	}
	lifecycleVpnState(t, "stopped", "stopped", false)
	after, err := captureProxySnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before.Proxies, after.Proxies) || !reflect.DeepEqual(before.Members, after.Members) ||
		!reflect.DeepEqual(before.Actual, after.Actual) || resolver.DefaultHostMapper != mapper {
		t.Fatal("attach/detach changed identities, selection or fake-IP mapper")
	}
	detached := runtimeSnapshot.Load()
	if detached.BootID != loaded.BootID || detached.ConfigRevision != loaded.ConfigRevision || detached.Revision <= loaded.Revision ||
		!detached.Running || detached.Forward != "stopped" || detached.StartedAt != 0 || detached.Mode != "global" ||
		current.AllowLan == nil || !*current.AllowLan {
		t.Fatalf("detach restarted or reconfigured core: %+v", detached)
	}

	lifecycleVpnState(t, "started", "preparing", true)
	if err := attachTun(12, tunNetworkOptions{Stack: "system", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	attached = tunListener
	lifecycleVpnState(t, "started", "running", true)
	badPath := lifecycleWriteProfile(t, options, "broken", "proxy-groups: [")
	if err := reload(badPath, "broken", new("one")); err == nil {
		t.Fatal("invalid selected profile fell back to empty core")
	}
	if state := runtimeSnapshot.Load(); state.Profile != "one" || state.ConfigRevision != loaded.ConfigRevision || tunListener != attached {
		t.Fatal("failed reload altered the live core")
	}
	if err := reload(path, "one", new("one")); err != nil {
		t.Fatal(err)
	}
	if state := runtimeSnapshot.Load(); state.BootID != loaded.BootID || state.ConfigRevision != loaded.ConfigRevision+1 || tunListener != attached {
		t.Fatal("connected reload rebuilt the platform TUN")
	}
	stale := attachIdentity{BootID: loaded.BootID, Profile: "one", ConfigRevision: loaded.ConfigRevision}
	if err := attachTun(12, tunNetworkOptions{Stack: "system", MTU: 1500, DNSHijacking: true}, stale); err == nil || tunListener != attached {
		t.Fatal("same-profile reload accepted stale attach identity")
	}
	if err := detachTun(); err != nil {
		t.Fatal(err)
	}
	lifecycleVpnState(t, "stopped", "stopped", false)
	if err := detachTun(); err != nil {
		t.Fatalf("duplicate detach failed: %v", err)
	}
	lifecycleVpnState(t, "started", "preparing", true)
	stop()
	if state := runtimeSnapshot.Load(); !state.VpnCreated || state.Forward != "failed" {
		t.Fatalf("full stop hid the platform VPN resource: %+v", state)
	}
	if err := start(options); err == nil {
		t.Fatal("new core started before the old platform VPN was released")
	}
	lifecycleVpnState(t, "stopped", "stopped", false)
	lifecycleController(t, options.Controller, false)
	if profile, online := runningProfile(); profile != "" || online {
		t.Fatal("full stop retained the active profile")
	}
	if state := runtimeSnapshot.Load(); state.Running || state.TunAttached || state.ListenersOpen || state.Forward != "stopped" {
		t.Fatalf("full stop retained forwarding resources: %+v", state)
	}
	if activeGeo.Load() != nil || runtimeRoutes.Load() != nil || len(tunnel.Proxies()) != 0 {
		t.Fatal("full stop retained core-owned workers or proxies")
	}
}

func TestLifecycleUncertainCloseCannotBecomeSuccessfulRetry(t *testing.T) {
	fixture(t)
	closeFailure := errors.New("fixture close failure")
	hostTunStopError = closeFailure
	if err := detachTun(); !errors.Is(err, closeFailure) {
		t.Fatalf("detach swallowed the TUN close error: %v", err)
	}
	hostTunStopError = nil
	if err := detachTun(); !errors.Is(err, closeFailure) {
		t.Fatalf("retry lost the cleanup uncertainty: %v", err)
	}
	mu.Lock()
	err := updateVpnState("stopped", "stopped", false)
	state := *runtimeSnapshot.Load()
	mu.Unlock()
	if err == nil || state.Forward != "failed" {
		t.Fatal("platform cleanup concealed an uncertain Go release")
	}
	if err := stop(); !errors.Is(err, closeFailure) {
		t.Fatalf("full stop lost cleanup error: %v", err)
	}
	if err := start(lifecycleOptions(t)); err == nil {
		t.Fatal("uncertain cleanup allowed a new core")
	}
}

func TestLifecycleSelectedConfigurationErrorsDoNotWarmFallback(t *testing.T) {
	options := lifecycleOptions(t)
	options.Profile = "selected"
	cases := []struct {
		name string
		path string
	}{
		{"missing path", ""},
		{"missing file", filepath.Join(options.HomeDir, "profiles", "missing.yaml")},
		{"empty file", lifecycleWriteProfile(t, options, "empty", "")},
		{"malformed YAML", lifecycleWriteProfile(t, options, "malformed", "rules: [")},
		{"invalid proxy", lifecycleWriteProfile(t, options, "invalid", "proxies: [{name: invalid, type: unknown}]\n")},
	}
	for _, item := range cases {
		t.Run(item.name, func(t *testing.T) {
			next := options
			next.ConfigPath = item.path
			if err := start(next); err == nil {
				stop()
				t.Fatal("selected configuration error started an empty core")
			}
			if _, online := runningProfile(); online || running || tunListener != nil {
				t.Fatal("failed start published a running core")
			}
		})
	}
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err == nil {
		t.Fatal("stopped core accepted a TUN")
	}
}

func TestLifecycleOverridesPreventPlatformTunOwnershipBypass(t *testing.T) {
	options := lifecycleOptions(t)
	raw := config.DefaultRawConfig()
	raw.Tun.Enable = true
	raw.Tun.AutoRoute = true
	raw.Tun.AutoRedirect = true
	raw.Tun.AutoDetectInterface = true
	raw.IPTables.Enable = true
	applyOverrides(raw, options)
	if raw.Tun.Enable || raw.Tun.AutoRoute || raw.Tun.AutoRedirect || raw.Tun.AutoDetectInterface || raw.IPTables.Enable {
		t.Fatal("subscription retained automatic TUN/routing ownership")
	}
	options.Profile = "custom"
	options.ConfigPath = lifecycleWriteProfile(t, options, "custom", "listeners:\n  - name: forbidden\n    type: tun\n    auto-route: true\n")
	if _, err := parseConfig(options.ConfigPath, options); err == nil {
		t.Fatal("custom TUN listener bypassed the platform fd")
	}
}

func TestLifecycleSelectedStartWithoutTunRestoresChoice(t *testing.T) {
	options := lifecycleOptions(t)
	options.Profile = "selected"
	options.ConfigPath = lifecycleWriteProfile(t, options, options.Profile, lifecycleProfile)
	if err := saveSelections(options.HomeDir, options.Profile, map[string]string{"Manual": "REJECT"}); err != nil {
		t.Fatal(err)
	}
	if err := start(options); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stop()
		lifecycleController(t, options.Controller, false)
	})
	lifecycleController(t, options.Controller, true)
	graph, err := captureProxySnapshot()
	if err != nil {
		t.Fatal(err)
	}
	if graph.Actual["Manual"] != graph.Proxies["REJECT"].ID {
		t.Fatal("selected start did not restore the profile choice")
	}
	if state := runtimeSnapshot.Load(); !state.Running || state.Profile != options.Profile ||
		state.TunAttached || state.VpnCreated || state.Forward != "stopped" || state.StartedAt != 0 {
		t.Fatalf("selected start unexpectedly attached forwarding: %+v", state)
	}
}

func TestLifecycleEmptyProfileExpectationCannotOverwriteNewSelection(t *testing.T) {
	options := lifecycleOptions(t)
	if err := start(options); err != nil {
		t.Fatal(err)
	}
	defer stop()
	path := lifecycleWriteProfile(t, options, "first", lifecycleProfile)
	if err := reload(path, "first", new("")); err != nil {
		t.Fatal(err)
	}
	before := *runtimeSnapshot.Load()
	if err := reload(path, "first", new("")); err == nil {
		t.Fatal("late empty-core activation overwrote an already loaded profile")
	}
	after := *runtimeSnapshot.Load()
	if before != after {
		t.Fatal("rejected empty-core activation changed runtime state")
	}
	if err := reload("", "", new("first")); err != nil {
		t.Fatal(err)
	}
	empty := runtimeSnapshot.Load()
	if !empty.Running || empty.Profile != "" || empty.BootID != before.BootID ||
		empty.ConfigRevision != before.ConfigRevision+1 || empty.TunAttached || empty.VpnCreated || empty.ListenersOpen {
		t.Fatalf("clearing last detached profile did not retain warm core: %+v", empty)
	}
	if err := reload(path, "first", nil); err != nil {
		t.Fatal(err)
	}
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	if err := reload("", "", new("first")); err == nil {
		t.Fatal("clearing last profile discarded a live TUN")
	}
}

func TestTunNetworkOptionsIgnoresAppAccessFields(t *testing.T) {
	payload := `{"stack":"gvisor","ipv6":true,"dnsHijacking":false,"mtu":1400,"congestionController":"bbr","bypassPrivateRoute":true,"routeAddress":["192.0.2.0/24"],"routeExcludeAddress":[],"appAccessMode":"trusted","excludedApplications":["com.example.direct"],"trustedApplications":["com.example.browser"]}`
	var got tunNetworkOptions
	if err := json.Unmarshal([]byte(payload), &got); err != nil {
		t.Fatalf("tunNetworkOptions failed to ignore app access fields: %v", err)
	}
	want := tunNetworkOptions{
		Stack:                "gvisor",
		IPv6:                 true,
		DNSHijacking:         false,
		MTU:                  1400,
		CongestionController: "bbr",
	}
	if got != want {
		t.Fatalf("decoded tunNetworkOptions = %+v, want %+v", got, want)
	}
}
