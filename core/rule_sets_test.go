package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/VOD-Studio/ArkClash/core/internal/ruleset"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

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
		BootID:           eng.Status().BootID,
		ExpectedRevision: "default", Revision: "imported", Action: "save",
		Item: ruleSetItem{ID: "remote", Name: "Remote", URL: server.URL, Behavior: "auto", Format: "auto"},
	}
	source.Store("payload: [first.test]\n")
	if err := changeRuleSet(context.Background(), catalog); err != nil {
		t.Fatal(err)
	}
	catalog.ExpectedRevision, catalog.Revision, catalog.Action = "imported", "bad-sync", "sync"
	source.Store("<html>Error</html>")
	if err := changeRuleSet(context.Background(), catalog); !errors.Is(err, ruleset.ErrContent) {
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
	active := eng.tun
	boot := eng.Status().BootID
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
	if err := save("initial", "broken", "payload: [https://broken.test/path]\n"); !errors.Is(err, ruleset.ErrContent) {
		t.Fatalf("invalid update: %v", err)
	}
	if !matches("sub.first.test") {
		t.Fatal("invalid update replaced the last good rule set")
	}
	item.Name = "Renamed"
	if err := save("initial", "updated", "payload: [second.test]\n"); err != nil {
		t.Fatal(err)
	}
	if matches("first.test") || !matches("second.test") || active != eng.tun || eng.Status().BootID != boot {
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
