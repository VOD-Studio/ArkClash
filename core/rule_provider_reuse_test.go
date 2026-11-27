package main

import (
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func reuseTestWrite(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
}

func reuseTestProfile(domains, cidrs, classical, missing string) string {
	return fmt.Sprintf(`mode: rule
log-level: silent
rule-providers:
  domains: {type: file, behavior: domain, format: text, path: %q}
  cidrs: {type: file, behavior: ipcidr, format: text, path: %q}
  classical: {type: file, behavior: classical, format: text, path: %q}
  missing: {type: file, behavior: domain, format: text, path: %q}
rules:
  - RULE-SET,domains,REJECT
  - RULE-SET,cidrs,REJECT
  - RULE-SET,classical,REJECT
  - RULE-SET,missing,REJECT
  - MATCH,DIRECT
`, domains, cidrs, classical, missing)
}

func reuseTestMatch(t *testing.T, name, host string) bool {
	t.Helper()
	rp, ok := tunnel.RuleProviders()[name]
	if !ok {
		t.Fatalf("rule provider %s is not live", name)
	}
	return rp.Match(&C.Metadata{Host: host}, C.RuleMatchHelper{})
}

func TestRuleProviderReuseAcrossReload(t *testing.T) {
	opts := lifecycleOptions(t)
	home := opts.HomeDir
	domains := filepath.Join(home, "domains.txt")
	cidrs := filepath.Join(home, "cidrs.txt")
	classical := filepath.Join(home, "classical.txt")
	missing := filepath.Join(home, "missing.txt")
	reuseTestWrite(t, domains, "reuse.example.test\n")
	reuseTestWrite(t, cidrs, "198.51.100.0/24\n")
	reuseTestWrite(t, classical, "DOMAIN,classical.example.test\n")
	opts.Profile = "reuse"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, opts.Profile, reuseTestProfile(domains, cidrs, classical, missing))
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	before := tunnel.RuleProviders()
	if before["missing"].Count() != 0 {
		t.Fatal("provider without a file unexpectedly loaded")
	}

	// 「missing」首次加载失败，空实例不复用；补上文件后热切换要能读到内容。
	reuseTestWrite(t, missing, "late.example.test\n")
	request := profileSettingsRequest[addedRulesSettings]{BootID: eng.Status().BootID, ExpectedRevision: "default",
		Settings: addedRulesSettings{Revision: "one", Rules: []addedRule{
			{ID: "one", Kind: "DOMAIN", Payload: "added.example.test", Target: "REJECT"}}}}
	if err := updateAddedRules(request); err != nil {
		t.Fatal(err)
	}
	after := tunnel.RuleProviders()
	if after["domains"] != before["domains"] || after["cidrs"] != before["cidrs"] {
		t.Fatal("unchanged domain and ipcidr providers were rebuilt on reload")
	}
	if after["classical"] == before["classical"] {
		t.Fatal("classical provider must be rebuilt on reload")
	}
	if !reuseTestMatch(t, "missing", "late.example.test") {
		t.Fatal("provider that failed to load was not retried")
	}
	if !reuseTestMatch(t, "domains", "reuse.example.test") || !reuseTestMatch(t, "classical", "classical.example.test") {
		t.Fatal("rule providers stopped matching after reload")
	}
	cidr := after["cidrs"].Match(&C.Metadata{DstIP: netip.MustParseAddr("198.51.100.7")}, C.RuleMatchHelper{})
	if !cidr {
		t.Fatal("reused ipcidr provider stopped matching")
	}
	if !ruleProviderLoaded(after["domains"]) {
		t.Fatal("reused provider is not marked as loaded")
	}

	// 定义变了（换了文件）就新建，读到新文件的内容。
	renamed := filepath.Join(home, "domains-next.txt")
	reuseTestWrite(t, renamed, "next.example.test\n")
	path := lifecycleWriteProfile(t, opts, opts.Profile, reuseTestProfile(renamed, cidrs, classical, missing))
	if err := reload(path, opts.Profile, nil); err != nil {
		t.Fatal(err)
	}
	changed := tunnel.RuleProviders()
	if changed["domains"] == after["domains"] || !reuseTestMatch(t, "domains", "next.example.test") ||
		reuseTestMatch(t, "domains", "reuse.example.test") {
		t.Fatal("provider with a changed definition kept the old instance")
	}
	if changed["cidrs"] != after["cidrs"] {
		t.Fatal("unrelated provider was rebuilt when another definition changed")
	}

	// 停止后清空，下一次启动不沿用上一轮内核的实例。
	if err := stop(); err != nil {
		t.Fatal(err)
	}
	if eng.ruleProviders.Load() != nil {
		t.Fatal("stop kept the applied rule providers")
	}
	opts.ConfigPath = path
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	if tunnel.RuleProviders()["cidrs"] == changed["cidrs"] {
		t.Fatal("restart reused a provider from the previous core")
	}
}

func TestRuleProviderKeyIgnoresMapOrder(t *testing.T) {
	first, ok := ruleProviderKey(map[string]any{"type": "http", "behavior": "domain", "url": "https://a.test/x", "interval": 86400})
	if !ok {
		t.Fatal("key failed")
	}
	second, _ := ruleProviderKey(map[string]any{"interval": 86400, "url": "https://a.test/x", "behavior": "domain", "type": "http"})
	third, _ := ruleProviderKey(map[string]any{"type": "http", "behavior": "domain", "url": "https://a.test/y", "interval": 86400})
	if first != second || first == third {
		t.Fatal("rule provider keys are not stable or not specific")
	}
	if _, ok := ruleProviderKey(map[string]any{"bad": make(chan int)}); ok {
		t.Fatal("unencodable definition must not get a key")
	}
	if reusableRuleProvider(nil) {
		t.Fatal("nil provider must not be reusable")
	}
}
