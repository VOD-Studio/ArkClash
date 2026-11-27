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
	if err := prependAddedRules(raw, list.Rules, "", nil); err != nil {
		t.Fatal(err)
	}
	want := []string{"DOMAIN,example.test,Proxy", "IP-CIDR,192.0.2.0/24,REJECT,no-resolve,src",
		"MATCH,REJECT", "DOMAIN,example.test,DIRECT", "MATCH,Proxy"}
	if !reflect.DeepEqual(raw.Rule, want) {
		t.Fatalf("unexpected effective order: %v", raw.Rule)
	}
	raw.Rule = []string{"DOMAIN,example.test,REJECT"}
	if err := prependAddedRules(raw, list.Rules, "", nil); !errors.Is(err, errAddedRulesMatchTarget) ||
		!reflect.DeepEqual(raw.Rule, []string{"DOMAIN,example.test,REJECT"}) {
		t.Fatalf("missing MATCH was accepted: %v, %v", raw.Rule, err)
	}
}

func TestNamedRuleExitsResolveFromFinalOutbounds(t *testing.T) {
	raw := config.DefaultRawConfig()
	raw.ProxyGroup = []map[string]any{{"name": "Media"}, {"name": "Mapped"}}
	raw.Proxy = []map[string]any{{"name": "Node"}}
	raw.Rule = []string{"MATCH,REJECT"}
	rules := []addedRule{
		{Kind: "DOMAIN", Payload: "explicit.test", Target: "Media", CustomExit: true},
		{Kind: "DOMAIN", Payload: "same.test", Target: "Node", CustomExit: true},
		{Kind: "DOMAIN", Payload: "fallback.test", Target: "Unavailable", CustomExit: true},
	}
	exits := []addedRuleExit{{Name: "Media", Target: "Mapped"}, {Name: "Unavailable", Target: "Gone"}}
	if err := prependAddedRules(raw, rules, "", exits); err != nil {
		t.Fatal(err)
	}
	want := []string{"DOMAIN,explicit.test,Mapped", "DOMAIN,same.test,Node", "DOMAIN,fallback.test,REJECT", "MATCH,REJECT"}
	if !reflect.DeepEqual(raw.Rule, want) {
		t.Fatalf("unexpected exit resolution: %v", raw.Rule)
	}
	raw.Rule = nil
	if err := prependAddedRules(raw, rules[2:], "", nil); err != nil ||
		!reflect.DeepEqual(raw.Rule, []string{"DOMAIN,fallback.test,DIRECT"}) {
		t.Fatalf("missing MATCH fallback: %v, %v", raw.Rule, err)
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
	boot, tun := eng.Status().BootID, eng.tun
	global := []addedRule{
		{ID: "global-one", Kind: "DOMAIN", Payload: "global.test", Target: "REJECT"},
		{ID: "global-two", Kind: "DOMAIN", Payload: "second.test", Target: "MATCH"},
	}
	request := profileSettingsRequest[addedRulesSettings]{BootID: boot, ExpectedRevision: "default",
		Settings: addedRulesSettings{Revision: "globals", Rules: global}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	before := eng.Status().ConfigRevision
	first := profileAddedRules{Profile: "first", Revision: "local", Disabled: []string{"global-one"}, MatchTarget: "DIRECT",
		Rules: []addedRule{{ID: "local", Kind: "DOMAIN", Payload: "global.test", Target: "MATCH"},
			{ID: "local-two", Kind: "DOMAIN", Payload: "local.test", Target: "REJECT"}}}
	request.ExpectedRevision = "globals"
	request.Settings = addedRulesSettings{Revision: "local", Rules: global, Profiles: []profileAddedRules{first}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if got := eng.Status(); got.ConfigRevision != before || got.StandardRulesRevision != "" {
		t.Fatal("saving a profile rule changed the runtime")
	}
	apply := scriptApplyRequest{BootID: boot, Profile: "first", StandardRevision: new("local")}
	if err := applyProfileScript(context.Background(), apply); err != nil {
		t.Fatal(err)
	}
	rules := tunnel.Rules()
	if got := eng.Status(); got.StandardRulesRevision != "local" || eng.tun != tun ||
		len(rules) != 4 || rules[0].Adapter() != "DIRECT" || rules[1].Adapter() != "REJECT" ||
		rules[2].Adapter() != "DIRECT" || rules[3].Adapter() != "GLOBAL" {
		t.Fatal("profile override order, MATCH target or TUN changed unexpectedly")
	}
	before = eng.Status().ConfigRevision
	if err := applyProfileScript(context.Background(), apply); err != nil || eng.Status().ConfigRevision != before {
		t.Fatalf("replaying the same apply changed runtime: %v", err)
	}
	request.ExpectedRevision = "local"
	request.Settings = addedRulesSettings{Revision: "remove-global", Rules: global[1:]}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	saved, err := readAddedRules(opts.HomeDir)
	if err != nil || len(saved.forProfile("first").Disabled) != 0 || eng.Status().ConfigRevision != before {
		t.Fatalf("deleting a disabled rule should clean its references without reloading: %v", err)
	}
	scriptPath := filepath.Join(opts.HomeDir, "profiles", "scripts.json")
	binding := `{"version":1,"scripts":[{"id":"test","revision":"first","source":"function main(c) { c['proxy-groups'] = [{name: 'Script Exit', type: 'select', proxies: ['DIRECT']}]; c.rules = ['MATCH,REJECT']; return c; }"}],"bindings":[{"profile":"first","mode":"script","scriptId":"test"}]}`
	if err := os.WriteFile(scriptPath, []byte(binding), 0600); err != nil {
		t.Fatal(err)
	}
	outbounds, err := readScriptOutbounds(t.Context(), opts.HomeDir, "first")
	if err != nil || len(outbounds.Groups) != 1 || outbounds.Groups[0].Name != "Script Exit" {
		t.Fatalf("script outbounds not available: %v, %v", outbounds, err)
	}
	const identity = "script:test:first"
	if err := applyProfileScript(context.Background(), scriptApplyRequest{BootID: boot, Profile: "first", Identity: identity}); err != nil {
		t.Fatal(err)
	}
	if rules := tunnel.Rules(); len(rules) != 4 || rules[0].Adapter() != "DIRECT" || rules[3].Adapter() != "REJECT" || eng.Status().StandardRulesRevision != "local" || eng.tun != tun {
		t.Fatal("script and added rules did not apply together")
	}
	named := saved.forProfile("first")
	named.Revision = "named-target"
	named.Rules[0].Target, named.Rules[0].CustomExit = "Media", true
	named.ExitTargets = []addedRuleExit{{Name: "Media", Target: "Script Exit"}}
	request.ExpectedRevision = saved.Revision
	request.Settings = addedRulesSettings{Revision: named.Revision, Rules: saved.Rules, Profiles: []profileAddedRules{named}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if err := applyProfileScript(t.Context(), scriptApplyRequest{BootID: boot, Profile: "first", Identity: identity,
		StandardRevision: &named.Revision}); err != nil || tunnel.Rules()[0].Adapter() != "Script Exit" || eng.tun != tun {
		t.Fatalf("named target was not applied to the scripted outbound: %v", err)
	}
	if err := os.Remove(scriptPath); err != nil {
		t.Fatal(err)
	}
	saved, err = readAddedRules(opts.HomeDir)
	if err != nil {
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
	before = eng.Status().ConfigRevision
	apply.StandardRevision = &invalid.Revision
	if err := applyProfileScript(context.Background(), apply); !errors.Is(err, errAddedRulesMatchTarget) || eng.Status().ConfigRevision != before || eng.Status().ProfileExtension != identity || eng.tun != tun {
		t.Fatalf("a missing target changed the runtime: %v", err)
	}
	fixed := saved.forProfile("first")
	fixed.Revision = "fixed-target"
	request.ExpectedRevision = invalid.Revision
	request.Settings = addedRulesSettings{Revision: "fixed-target", Rules: saved.Rules, Profiles: []profileAddedRules{fixed}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	apply.StandardRevision = &fixed.Revision
	if err := applyProfileScript(context.Background(), apply); err != nil || len(tunnel.Rules()) != 4 || eng.Status().StandardRulesRevision != fixed.Revision || eng.tun != tun {
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
	if rules := tunnel.Rules(); len(rules) != 1 || rules[0].Adapter() != "REJECT" || eng.tun != tun {
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
	boot := eng.Status().BootID
	active := eng.tun
	request := profileSettingsRequest[addedRulesSettings]{BootID: boot, ExpectedRevision: "default",
		Settings: addedRulesSettings{Revision: "rules.1", Rules: []addedRule{
			{ID: "first", Kind: "DOMAIN", Payload: "example.test", Target: "MATCH"},
			{ID: "second", Kind: "DOMAIN", Payload: "example.test", Target: "DIRECT"},
		}}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if rules := tunnel.Rules(); len(rules) != 4 || rules[0].Adapter() != "REJECT" || rules[1].Adapter() != "DIRECT" || eng.tun !=
		active || eng.Status().BootID != boot {
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
	if rules := tunnel.Rules(); len(rules) != 3 || rules[0].Adapter() != "GLOBAL" || eng.tun != active {
		t.Fatal("profile switch did not recalculate MATCH-TARGET on the existing tunnel")
	}
	request.Settings = addedRulesSettings{Revision: "removed", Rules: []addedRule{}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if len(tunnel.Rules()) != 1 || eng.tun != active {
		t.Fatal("deleting the added rules did not restore the original profile rules")
	}
}
