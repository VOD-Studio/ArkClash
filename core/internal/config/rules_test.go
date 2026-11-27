package config

import (
	"errors"
	"reflect"
	"testing"

	mihomoConfig "github.com/metacubex/mihomo/config"
)

func TestAddedRulesPreserveOrderAndMatchTarget(t *testing.T) {
	list := AddedRulesSettings{Revision: "current", Rules: []AddedRule{
		{ID: "a", Kind: "DOMAIN", Payload: "example.test", Target: "MATCH"},
		{ID: "b", Kind: "IP-CIDR", Payload: "192.0.2.0/24", Target: "REJECT", NoResolve: true, Source: true},
	}}
	raw := mihomoConfig.DefaultRawConfig()
	raw.ProxyGroup = []map[string]any{{"name": "Proxy"}}
	raw.Rule = []string{"MATCH,REJECT", "DOMAIN,example.test,DIRECT", "MATCH,Proxy"}
	if err := PrependAddedRules(raw, list.Rules, "", nil); err != nil {
		t.Fatal(err)
	}
	want := []string{"DOMAIN,example.test,Proxy", "IP-CIDR,192.0.2.0/24,REJECT,no-resolve,src",
		"MATCH,REJECT", "DOMAIN,example.test,DIRECT", "MATCH,Proxy"}
	if !reflect.DeepEqual(raw.Rule, want) {
		t.Fatalf("unexpected effective order: %v", raw.Rule)
	}
	raw.Rule = []string{"DOMAIN,example.test,REJECT"}
	if err := PrependAddedRules(raw, list.Rules, "", nil); !errors.Is(err, ErrAddedRulesMatchTarget) ||
		!reflect.DeepEqual(raw.Rule, []string{"DOMAIN,example.test,REJECT"}) {
		t.Fatalf("missing MATCH was accepted: %v, %v", raw.Rule, err)
	}
}

func TestNamedRuleExitsResolveFromFinalOutbounds(t *testing.T) {
	raw := mihomoConfig.DefaultRawConfig()
	raw.ProxyGroup = []map[string]any{{"name": "Media"}, {"name": "Mapped"}}
	raw.Proxy = []map[string]any{{"name": "Node"}}
	raw.Rule = []string{"MATCH,REJECT"}
	rules := []AddedRule{
		{Kind: "DOMAIN", Payload: "explicit.test", Target: "Media", CustomExit: true},
		{Kind: "DOMAIN", Payload: "same.test", Target: "Node", CustomExit: true},
		{Kind: "DOMAIN", Payload: "fallback.test", Target: "Unavailable", CustomExit: true},
	}
	exits := []AddedRuleExit{{Name: "Media", Target: "Mapped"}, {Name: "Unavailable", Target: "Gone"}}
	if err := PrependAddedRules(raw, rules, "", exits); err != nil {
		t.Fatal(err)
	}
	want := []string{"DOMAIN,explicit.test,Mapped", "DOMAIN,same.test,Node", "DOMAIN,fallback.test,REJECT", "MATCH,REJECT"}
	if !reflect.DeepEqual(raw.Rule, want) {
		t.Fatalf("unexpected exit resolution: %v", raw.Rule)
	}
	raw.Rule = nil
	if err := PrependAddedRules(raw, rules[2:], "", nil); err != nil ||
		!reflect.DeepEqual(raw.Rule, []string{"DOMAIN,fallback.test,DIRECT"}) {
		t.Fatalf("missing MATCH fallback: %v, %v", raw.Rule, err)
	}
}
