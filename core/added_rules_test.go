package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/mihomo/tunnel"
)

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
	global := []corecfg.AddedRule{
		{ID: "global-one", Kind: "DOMAIN", Payload: "global.test", Target: "REJECT"},
		{ID: "global-two", Kind: "DOMAIN", Payload: "second.test", Target: "MATCH"},
	}
	request := corecfg.SettingsRequest[corecfg.AddedRulesSettings]{BootID: boot, ExpectedRevision: "default",
		Settings: corecfg.AddedRulesSettings{Revision: "globals", Rules: global}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	before := eng.Status().ConfigRevision
	first := corecfg.ProfileAddedRules{Profile: "first", Revision: "local", Disabled: []string{"global-one"}, MatchTarget: "DIRECT",
		Rules: []corecfg.AddedRule{{ID: "local", Kind: "DOMAIN", Payload: "global.test", Target: "MATCH"},
			{ID: "local-two", Kind: "DOMAIN", Payload: "local.test", Target: "REJECT"}}}
	request.ExpectedRevision = "globals"
	request.Settings = corecfg.AddedRulesSettings{Revision: "local", Rules: global, Profiles: []corecfg.ProfileAddedRules{first}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if got := eng.Status(); got.ConfigRevision != before || got.StandardRulesRevision != "" {
		t.Fatal("saving a profile rule changed the runtime")
	}
	apply := corecfg.ScriptApplyRequest{BootID: boot, Profile: "first", StandardRevision: new("local")}
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
	request.Settings = corecfg.AddedRulesSettings{Revision: "remove-global", Rules: global[1:]}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	saved, err := corecfg.ReadAddedRules(opts.HomeDir)
	if err != nil || len(saved.ForProfile("first").Disabled) != 0 || eng.Status().ConfigRevision != before {
		t.Fatalf("deleting a disabled rule should clean its references without reloading: %v", err)
	}
	scriptPath := filepath.Join(opts.HomeDir, "profiles", "scripts.json")
	binding := `{"version":1,"scripts":[{"id":"test","revision":"first","source":"function main(c) { c['proxy-groups'] = [{name: 'Script Exit', type: 'select', proxies: ['DIRECT']}]; c.rules = ['MATCH,REJECT']; return c; }"}],"bindings":[{"profile":"first","mode":"script","scriptId":"test"}]}`
	if err := os.WriteFile(scriptPath, []byte(binding), 0600); err != nil {
		t.Fatal(err)
	}
	outbounds, err := corecfg.ReadScriptOutbounds(t.Context(), opts.HomeDir, "first")
	if err != nil || len(outbounds.Groups) != 1 || outbounds.Groups[0].Name != "Script Exit" {
		t.Fatalf("script outbounds not available: %v, %v", outbounds, err)
	}
	const identity = "script:test:first"
	if err := applyProfileScript(context.Background(), corecfg.ScriptApplyRequest{BootID: boot, Profile: "first", Identity: identity}); err != nil {
		t.Fatal(err)
	}
	if rules := tunnel.Rules(); len(rules) != 4 || rules[0].Adapter() != "DIRECT" || rules[3].Adapter() != "REJECT" || eng.Status().StandardRulesRevision != "local" || eng.tun != tun {
		t.Fatal("script and added rules did not apply together")
	}
	named := saved.ForProfile("first")
	named.Revision = "named-target"
	named.Rules[0].Target, named.Rules[0].CustomExit = "Media", true
	named.ExitTargets = []corecfg.AddedRuleExit{{Name: "Media", Target: "Script Exit"}}
	request.ExpectedRevision = saved.Revision
	request.Settings = corecfg.AddedRulesSettings{Revision: named.Revision, Rules: saved.Rules, Profiles: []corecfg.ProfileAddedRules{named}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if err := applyProfileScript(t.Context(), corecfg.ScriptApplyRequest{BootID: boot, Profile: "first", Identity: identity,
		StandardRevision: &named.Revision}); err != nil || tunnel.Rules()[0].Adapter() != "Script Exit" || eng.tun != tun {
		t.Fatalf("named target was not applied to the scripted outbound: %v", err)
	}
	if err := os.Remove(scriptPath); err != nil {
		t.Fatal(err)
	}
	saved, err = corecfg.ReadAddedRules(opts.HomeDir)
	if err != nil {
		t.Fatal(err)
	}
	invalid := saved.ForProfile("first")
	invalid.Revision, invalid.MatchTarget = "invalid-target", "missing-target"
	request.ExpectedRevision = saved.Revision
	request.Settings = corecfg.AddedRulesSettings{Revision: "invalid-target", Rules: saved.Rules, Profiles: []corecfg.ProfileAddedRules{invalid}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if err := applyProfileScript(context.Background(), apply); !errors.Is(err, corecfg.ErrSettingsConflict) {
		t.Fatalf("a stale standard revision was accepted: %v", err)
	}
	before = eng.Status().ConfigRevision
	apply.StandardRevision = &invalid.Revision
	if err := applyProfileScript(context.Background(), apply); !errors.Is(err, corecfg.ErrAddedRulesMatchTarget) || eng.Status().ConfigRevision != before || eng.Status().ProfileExtension != identity || eng.tun != tun {
		t.Fatalf("a missing target changed the runtime: %v", err)
	}
	fixed := saved.ForProfile("first")
	fixed.Revision = "fixed-target"
	request.ExpectedRevision = invalid.Revision
	request.Settings = corecfg.AddedRulesSettings{Revision: "fixed-target", Rules: saved.Rules, Profiles: []corecfg.ProfileAddedRules{fixed}}
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
	request := corecfg.SettingsRequest[corecfg.AddedRulesSettings]{BootID: boot, ExpectedRevision: "default",
		Settings: corecfg.AddedRulesSettings{Revision: "rules.1", Rules: []corecfg.AddedRule{
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
	saved, err := corecfg.ReadAddedRules(opts.HomeDir)
	if err != nil || saved.Revision != "rules.1" || saved.Rules[1].ID != "second" {
		t.Fatalf("rule order was not persisted: %v", err)
	}
	if err := updateAddedRules(request); !errors.Is(err, corecfg.ErrSettingsConflict) {
		t.Fatalf("stale rule revision accepted: %v", err)
	}
	request.ExpectedRevision = "rules.1"
	request.Settings = corecfg.AddedRulesSettings{Revision: "rejected", Rules: []corecfg.AddedRule{
		{ID: "broken", Kind: "IP-CIDR", Payload: "invalid-prefix", Target: "DIRECT"},
	}}
	if err := updateAddedRules(request); !errors.Is(err, corecfg.ErrSettingsInvalid) {
		t.Fatalf("invalid rule accepted: %v", err)
	}
	if err := reload(second, "second", new("first")); err != nil {
		t.Fatal(err)
	}
	if rules := tunnel.Rules(); len(rules) != 3 || rules[0].Adapter() != "GLOBAL" || eng.tun != active {
		t.Fatal("profile switch did not recalculate MATCH-TARGET on the existing tunnel")
	}
	request.Settings = corecfg.AddedRulesSettings{Revision: "removed", Rules: []corecfg.AddedRule{}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	if len(tunnel.Rules()) != 1 || eng.tun != active {
		t.Fatal("deleting the added rules did not restore the original profile rules")
	}
}
