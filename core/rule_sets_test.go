package main

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	RP "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
)

func TestRuleSetFormats(t *testing.T) {
	for _, fixture := range []struct {
		behavior, format, source, compiled string
	}{
		{"domain", "yaml", "payload: [+.example.test, other.test]\n", "+.example.test\nother.test\n"},
		{"ipcidr", "text", "# test\n192.0.2.1/24\n", "192.0.2.0/24\n"},
		{"classical", "yaml", "rules:\n  - DOMAIN-SUFFIX,example.test\n", "DOMAIN-SUFFIX,example.test\n"},
	} {
		got, _, err := compileRuleSet([]byte(fixture.source), fixture.behavior, fixture.format)
		if err != nil || string(got) != fixture.compiled {
			t.Fatalf("%s %s: %q, %v", fixture.behavior, fixture.format, got, err)
		}
	}
	for _, fixture := range []struct {
		kind       P.RuleBehavior
		name, text string
	}{
		{P.Domain, "domain", "+.example.test\nfoo.test\n"},
		{P.IPCIDR, "ipcidr", "192.0.2.0/24\n2001:db8::/32\n"},
	} {
		var binary bytes.Buffer
		if err := RP.ConvertToMrs([]byte(fixture.text), fixture.kind, P.TextRule, &binary); err != nil {
			t.Fatal(err)
		}
		if detectRuleSetFormat(binary.Bytes()) != "mrs" {
			t.Fatal("MRS was not detected")
		}
		got, count, err := compileRuleSet(binary.Bytes(), fixture.name, "mrs")
		if err != nil || count != 2 || !bytes.Contains(got, []byte(fixture.text[:12])) {
			t.Fatalf("MRS %s: %q, %d, %v", fixture.name, got, count, err)
		}
		if _, _, err := compileRuleSet(binary.Bytes()[:binary.Len()-1], fixture.name, "mrs"); err == nil {
			t.Fatal("truncated MRS accepted")
		}
	}
	if _, _, err := compileRuleSet([]byte("RULE-SET,recursive\n"), "classical", "text"); err == nil {
		t.Fatal("classical set accepted a rule that depends on another provider")
	}
}

func TestRuleSetRemoteSyncRejectsBadContent(t *testing.T) {
	opts := lifecycleOptions(t)
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	var source atomic.Value
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(source.Load().(string)))
	}))
	defer server.Close()
	catalog := ruleSetRequest{
		BootID:           runtimeSnapshot.Load().BootID,
		ExpectedRevision: "default", Revision: "imported", Action: "save",
		Item: ruleSetItem{ID: "remote", Name: "Remote", URL: server.URL, Behavior: "auto", Format: "auto"},
	}
	source.Store("payload: [first.test]\n")
	if err := changeRuleSet(context.Background(), catalog); err != nil {
		t.Fatal(err)
	}
	catalog.ExpectedRevision, catalog.Revision, catalog.Action = "imported", "bad-sync", "sync"
	source.Store("<html>Error</html>")
	if err := changeRuleSet(context.Background(), catalog); !errors.Is(err, errRuleSetContent) {
		t.Fatalf("invalid response was not rejected: %v", err)
	}
	catalog.Revision = "good-sync"
	source.Store("payload: [second.test]\n")
	if err := changeRuleSet(context.Background(), catalog); err != nil {
		t.Fatal(err)
	}
	saved, err := readRuleSets(opts.HomeDir)
	if err != nil || saved.Revision != "good-sync" || len(saved.Items) != 1 || saved.Items[0].Content != "good-sync" {
		t.Fatalf("sync did not publish the new version: %v", err)
	}
}

func TestRuleSetLiveUpdateKeepsTunnelAndLastGoodData(t *testing.T) {
	opts := lifecycleOptions(t)
	opts.Profile = "first"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, opts.Profile, "mode: rule\nlog-level: silent\nrules: ['MATCH,DIRECT']\n")
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	active := tunListener
	boot := runtimeSnapshot.Load().BootID
	item := ruleSetItem{ID: "demo", Name: "Imported", Behavior: "auto", Format: "auto"}
	save := func(expected, revision, source string) error {
		t.Helper()
		if err := os.WriteFile(filepath.Join(opts.HomeDir, "profiles", revision+".ruleset"), []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
		return changeRuleSet(context.Background(), ruleSetRequest{
			BootID: boot, ExpectedRevision: expected, Revision: revision, Action: "save", Item: item, Candidate: revision,
		})
	}
	if err := save("default", "initial", "payload: [+.first.test]\n"); err != nil {
		t.Fatal(err)
	}
	if len(tunnel.RuleProviders()) != 0 {
		t.Fatal("unused rule set was loaded")
	}
	rules := []addedRule{
		{ID: "a", Kind: "RULE-SET", Payload: item.ID, Target: "REJECT"},
		{ID: "b", Kind: "RULE-SET", Payload: item.ID, Target: "DIRECT"},
	}
	if err := updateAddedRules(profileSettingsRequest[addedRulesSettings]{BootID: boot, ExpectedRevision: "default",
		Settings: addedRulesSettings{Revision: "rule-1", Rules: rules}}); err != nil {
		t.Fatal(err)
	}
	matches := func(host string) bool {
		rule := tunnel.Rules()[0]
		ok, adapter := rule.Match(&C.Metadata{Host: host}, C.RuleMatchHelper{})
		return ok && adapter == "REJECT"
	}
	if !matches("sub.first.test") || matches("second.test") || len(tunnel.RuleProviders()) != 1 {
		t.Fatal("rule provider did not attach to both references")
	}
	if err := save("initial", "broken", "payload: [https://broken.test/path]\n"); !errors.Is(err, errRuleSetContent) {
		t.Fatalf("invalid update: %v", err)
	}
	if !matches("sub.first.test") {
		t.Fatal("invalid update replaced the last good rule set")
	}
	item.Name = "Renamed"
	if err := save("initial", "updated", "payload: [second.test]\n"); err != nil {
		t.Fatal(err)
	}
	if matches("first.test") || !matches("second.test") || active != tunListener || runtimeSnapshot.Load().BootID != boot {
		t.Fatal("rule set update failed to preserve the tunnel or replace the matcher")
	}
	if err := changeRuleSet(context.Background(), ruleSetRequest{
		BootID: boot, ExpectedRevision: "updated", Revision: "delete", Action: "delete", Item: item,
	}); !errors.Is(err, errRuleSetInUse) {
		t.Fatalf("referenced rule set was deletable: %v", err)
	}
	if err := reload(opts.ConfigPath, opts.Profile, new(opts.Profile)); err != nil || !matches("second.test") {
		t.Fatalf("rule set did not survive configuration reload: %v", err)
	}
}
