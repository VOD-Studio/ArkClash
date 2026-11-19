package main

import (
	"errors"
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
	raw.Rule = []string{"MATCH,REJECT", "DOMAIN,example.test,DIRECT", "MATCH,Proxy"}
	list.apply(raw)
	want := []string{"DOMAIN,example.test,Proxy", "IP-CIDR,192.0.2.0/24,REJECT,no-resolve,src",
		"MATCH,REJECT", "DOMAIN,example.test,DIRECT", "MATCH,Proxy"}
	if !reflect.DeepEqual(raw.Rule, want) {
		t.Fatalf("unexpected effective order: %v", raw.Rule)
	}
	raw.Rule = []string{"DOMAIN,example.test,REJECT"}
	list.apply(raw)
	if raw.Rule[0] != "DOMAIN,example.test,DIRECT" {
		t.Fatalf("unexpected implicit target: %s", raw.Rule[0])
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
