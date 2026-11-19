package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
)

func TestAddedRulesPreserveOrderAndMatchTarget(t *testing.T) {
	list := addedRulesSettings{Revision: "current", Rules: []addedRule{
		{ID: "a", Kind: "DOMAIN", Payload: "example.test", Target: "MATCH"},
		{ID: "b", Kind: "IP-CIDR", Payload: "192.0.2.0/24", Target: "REJECT", NoResolve: true, Source: true},
	}}
	raw := config.DefaultRawConfig()
	raw.ProxyGroup = []map[string]any{{"name": "Proxy"}}
	raw.Rule = []string{"MATCH,REJECT", "DOMAIN,example.test,DIRECT", "MATCH,Proxy"}
	if err := prependAddedRules(raw, list.Rules, ""); err != nil {
		t.Fatal(err)
	}
	want := []string{"DOMAIN,example.test,Proxy", "IP-CIDR,192.0.2.0/24,REJECT,no-resolve,src",
		"MATCH,REJECT", "DOMAIN,example.test,DIRECT", "MATCH,Proxy"}
	if !reflect.DeepEqual(raw.Rule, want) {
		t.Fatalf("unexpected effective order: %v", raw.Rule)
	}
	raw.Rule = []string{"DOMAIN,example.test,REJECT"}
	if err := prependAddedRules(raw, list.Rules, ""); !errors.Is(err, errAddedRulesMatchTarget) ||
		!reflect.DeepEqual(raw.Rule, []string{"DOMAIN,example.test,REJECT"}) {
		t.Fatalf("missing MATCH was accepted: %v, %v", raw.Rule, err)
	}
}

func TestProfileAddedRulesSaveAndApplyRespectScope(t *testing.T) {
	opts := lifecycleOptions(t)
	opts.Profile = "first"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, opts.Profile, "mode: rule\nlog-level: silent\nrules: ['MATCH,GLOBAL']\n")
	second := lifecycleWriteProfile(t, opts, "second", "mode: rule\nlog-level: silent\nrules: ['MATCH,DIRECT']\n")
	custom := lifecycleWriteProfile(t, opts, "custom", "mode: rule\nlog-level: silent\nrules: ['MATCH,REJECT']\n")
	listPath := filepath.Join(opts.HomeDir, "profiles", "list.json")
	if err := os.WriteFile(listPath, []byte(`{"profiles":[{"id":"first"},{"id":"second"},{"id":"custom","type":"custom"}]}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	boot, tun := runtimeSnapshot.Load().BootID, tunListener
	global := []addedRule{
		{ID: "global-one", Kind: "DOMAIN", Payload: "global.test", Target: "REJECT"},
		{ID: "global-two", Kind: "DOMAIN", Payload: "second.test", Target: "MATCH"},
	}
	request := profileSettingsRequest[addedRulesSettings]{BootID: boot, ExpectedRevision: "default",
		Settings: addedRulesSettings{Revision: "globals", Rules: global}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	before := runtimeSnapshot.Load().ConfigRevision
	first := profileAddedRules{Profile: "first", Revision: "local", Disabled: []string{"global-one"}, MatchTarget: "DIRECT",
		Rules: []addedRule{{ID: "local", Kind: "DOMAIN", Payload: "global.test", Target: "MATCH"},
			{ID: "local-two", Kind: "DOMAIN", Payload: "local.test", Target: "REJECT"}}}
	request.ExpectedRevision = "globals"
	request.Settings = addedRulesSettings{Revision: "local", Rules: global, Profiles: []profileAddedRules{first}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if got := runtimeSnapshot.Load(); got.ConfigRevision != before || got.StandardRulesRevision != "" {
		t.Fatal("saving a profile rule changed the runtime")
	}
	apply := scriptApplyRequest{BootID: boot, Profile: "first", StandardRevision: "local"}
	if err := applyProfileScript(context.Background(), apply); err != nil {
		t.Fatal(err)
	}
	rules := tunnel.Rules()
	if got := runtimeSnapshot.Load(); got.StandardRulesRevision != "local" || tunListener != tun ||
		len(rules) != 4 || rules[0].Adapter() != "DIRECT" || rules[1].Adapter() != "REJECT" ||
		rules[2].Adapter() != "DIRECT" || rules[3].Adapter() != "GLOBAL" {
		t.Fatal("profile override order, MATCH target or TUN changed unexpectedly")
	}
	before = runtimeSnapshot.Load().ConfigRevision
	if err := applyProfileScript(context.Background(), apply); err != nil || runtimeSnapshot.Load().ConfigRevision != before {
		t.Fatalf("replaying the same apply changed runtime: %v", err)
	}
	request.ExpectedRevision = "local"
	request.Settings = addedRulesSettings{Revision: "remove-global", Rules: global[1:]}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	saved, err := readAddedRules(opts.HomeDir)
	if err != nil || len(saved.forProfile("first").Disabled) != 0 || runtimeSnapshot.Load().ConfigRevision != before {
		t.Fatalf("deleting a disabled rule should clean its references without reloading: %v", err)
	}
	scriptPath := filepath.Join(opts.HomeDir, "profiles", "scripts.json")
	binding := `{"version":1,"scripts":[],"bindings":[{"profile":"first","mode":"script","scriptId":""}]}`
	if err := os.WriteFile(scriptPath, []byte(binding), 0600); err != nil {
		t.Fatal(err)
	}
	if err := applyProfileScript(context.Background(), scriptApplyRequest{BootID: boot, Profile: "first", Identity: "script"}); err != nil {
		t.Fatal(err)
	}
	if rules := tunnel.Rules(); len(rules) != 1 || rules[0].Adapter() != "GLOBAL" {
		t.Fatal("script mode inherited standard rules")
	}
	if err := os.Remove(scriptPath); err != nil {
		t.Fatal(err)
	}
	invalid := saved.forProfile("first")
	invalid.Revision, invalid.MatchTarget = "invalid-target", "missing-target"
	request.ExpectedRevision = saved.Revision
	request.Settings = addedRulesSettings{Revision: "invalid-target", Rules: saved.Rules, Profiles: []profileAddedRules{invalid}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if err := applyProfileScript(context.Background(), apply); !errors.Is(err, errProfileSettingsConflict) {
		t.Fatalf("a stale standard revision was accepted: %v", err)
	}
	before = runtimeSnapshot.Load().ConfigRevision
	apply.StandardRevision = invalid.Revision
	if err := applyProfileScript(context.Background(), apply); !errors.Is(err, errAddedRulesMatchTarget) ||
		runtimeSnapshot.Load().ConfigRevision != before || runtimeSnapshot.Load().ProfileExtension != "script" || tunListener != tun {
		t.Fatalf("a missing target changed the runtime: %v", err)
	}
	fixed := saved.forProfile("first")
	fixed.Revision = "fixed-target"
	request.ExpectedRevision = invalid.Revision
	request.Settings = addedRulesSettings{Revision: "fixed-target", Rules: saved.Rules, Profiles: []profileAddedRules{fixed}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	apply.StandardRevision = fixed.Revision
	if err := applyProfileScript(context.Background(), apply); err != nil || len(tunnel.Rules()) != 4 ||
		runtimeSnapshot.Load().StandardRulesRevision != fixed.Revision || tunListener != tun {
		t.Fatalf("switching back did not restore saved standard rules: %v", err)
	}
	if err := reload(second, "second", new("first")); err != nil {
		t.Fatal(err)
	}
	if rules := tunnel.Rules(); len(rules) != 2 || rules[0].Adapter() != "DIRECT" {
		t.Fatal("profile rules leaked during the switch")
	}
	if err := reload(custom, "custom", new("second")); err != nil {
		t.Fatal(err)
	}
	if rules := tunnel.Rules(); len(rules) != 1 || rules[0].Adapter() != "REJECT" || tunListener != tun {
		t.Fatal("custom configuration inherited standard rules")
	}
}

func TestAddedRulesLiveApplyAndSwitchPreserveTun(t *testing.T) {
	opts := lifecycleOptions(t)
	opts.Profile = "first"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, opts.Profile,
		"mode: rule\nlog-level: silent\nrules: ['DOMAIN,example.test,DIRECT', 'MATCH,REJECT']\n")
	second := lifecycleWriteProfile(t, opts, "second", "mode: rule\nlog-level: silent\nrules: ['MATCH,GLOBAL']\n")
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	boot := runtimeSnapshot.Load().BootID
	active := tunListener
	request := profileSettingsRequest[addedRulesSettings]{BootID: boot, ExpectedRevision: "default",
		Settings: addedRulesSettings{Revision: "rules.1", Rules: []addedRule{
			{ID: "first", Kind: "DOMAIN", Payload: "example.test", Target: "MATCH"},
			{ID: "second", Kind: "DOMAIN", Payload: "example.test", Target: "DIRECT"},
		}}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if rules := tunnel.Rules(); len(rules) != 4 || rules[0].Adapter() != "REJECT" || rules[1].Adapter() != "DIRECT" ||
		tunListener != active || runtimeSnapshot.Load().BootID != boot {
		t.Fatal("live rule update did not prepend rules or preserve the live tunnel")
	}
	saved, err := readAddedRules(opts.HomeDir)
	if err != nil || saved.Revision != "rules.1" || saved.Rules[1].ID != "second" {
		t.Fatalf("rule order was not persisted: %v", err)
	}
	if err := updateAddedRules(request); !errors.Is(err, errProfileSettingsConflict) {
		t.Fatalf("stale rule revision accepted: %v", err)
	}
	request.ExpectedRevision = "rules.1"
	request.Settings = addedRulesSettings{Revision: "rejected", Rules: []addedRule{
		{ID: "broken", Kind: "IP-CIDR", Payload: "invalid-prefix", Target: "DIRECT"},
	}}
	if err := updateAddedRules(request); !errors.Is(err, errProfileSettingsInvalid) {
		t.Fatalf("invalid rule accepted: %v", err)
	}
	if err := reload(second, "second", new("first")); err != nil {
		t.Fatal(err)
	}
	if rules := tunnel.Rules(); len(rules) != 3 || rules[0].Adapter() != "GLOBAL" || tunListener != active {
		t.Fatal("profile switch did not recalculate MATCH-TARGET on the existing tunnel")
	}
	request.Settings = addedRulesSettings{Revision: "removed", Rules: []addedRule{}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if len(tunnel.Rules()) != 1 || tunListener != active {
		t.Fatal("deleting the added rules did not restore the original profile rules")
	}
}
