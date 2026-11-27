package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/providers"
	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	RP "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
)

func providerTestStart(t *testing.T, home, profileID, yamlContent string) (string, uint64) {
	t.Helper()
	profilesDir := filepath.Join(home, "profiles")
	if err := os.MkdirAll(profilesDir, 0o700); err != nil {
		t.Fatalf("mkdir profiles: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(home, "profile-work"), 0o700); err != nil {
		t.Fatalf("mkdir profile-work: %v", err)
	}
	configPath := filepath.Join(profilesDir, profileID+".yaml")
	if err := os.WriteFile(configPath, []byte(yamlContent), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	err := start(startOptions{
		HomeDir:    home,
		ConfigPath: configPath,
		Controller: "127.0.0.1:0",
		Secret:     "provider-test-secret",
		Profile:    profileID,
	})
	if err != nil {
		t.Fatalf("start core: %v", err)
	}
	tunnel.ArkClashResumeForwarding()
	t.Cleanup(func() { _ = stop() })
	status := runtimeSnapshot.Load()
	if status == nil {
		t.Fatal("missing runtime status after start")
	}
	return status.BootID, status.ConfigRevision
}

func doJSONRequest(handler http.HandlerFunc, method, target string, payload any) *httptest.ResponseRecorder {
	var body *bytes.Reader
	if payload != nil {
		raw, _ := json.Marshal(payload)
		body = bytes.NewReader(raw)
	} else {
		body = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, target, body)
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	handler(rec, req)
	return rec
}

func findProviderItem(t *testing.T, items []providers.Item, kind, name string) providers.Item {
	t.Helper()
	for _, item := range items {
		if item.Kind == kind && item.Name == name {
			return item
		}
	}
	t.Fatalf("provider (%s, %s) not found in %+v", kind, name, items)
	return providers.Item{}
}

func TestProvidersSameNameDistinguishedAndManagedExcluded(t *testing.T) {
	home := t.TempDir()
	proxyFile := filepath.Join(home, "shared-proxies.yaml")
	ruleFile := filepath.Join(home, "shared-rules.yaml")
	if err := os.WriteFile(proxyFile, []byte("proxies:\n  - { name: P1, type: ss, server: 1.1.1.1, port: 8388, cipher: aes-128-gcm, password: pass }\n  - { name: P2, type: ss, server: 1.1.1.2, port: 8388, cipher: aes-128-gcm, password: pass }\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ruleFile, []byte("payload:\n  - 'example.test'\n  - 'sub.example.test'\n  - 'third.example.test'\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := fmt.Sprintf(`mode: rule
proxy-providers:
  shared:
    type: file
    path: %s
  inline-p:
    type: inline
    payload:
      - { name: Inline-1, type: ss, server: 2.2.2.2, port: 8388, cipher: aes-128-gcm, password: pass }
rule-providers:
  shared:
    type: file
    behavior: domain
    format: yaml
    path: %s
  inline-r:
    type: inline
    behavior: domain
    payload:
      - 'inline.example.test'
proxy-groups:
  - name: Proxy
    type: select
    use: [shared, inline-p]
    proxies: [DIRECT]
rules:
  - RULE-SET,shared,Proxy
  - RULE-SET,inline-r,DIRECT
  - MATCH,Proxy
`, proxyFile, ruleFile)
	bootID, rev := providerTestStart(t, home, "p-same", cfg)

	rec := doJSONRequest(runtimeProviders.HandleList, http.MethodGet, "/arkclash/providers", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /arkclash/providers status=%d body=%s", rec.Code, rec.Body.String())
	}
	var snap providers.Snapshot
	if err := json.Unmarshal(rec.Body.Bytes(), &snap); err != nil {
		t.Fatalf("decode snapshot: %v", err)
	}
	if snap.BootID != bootID || snap.ConfigRevision != rev || snap.Profile != "p-same" {
		t.Fatalf("unexpected identity: %+v", snap)
	}
	if len(snap.Items) != 4 {
		t.Fatalf("expected 4 user providers (no Compatible), got %d: %+v", len(snap.Items), snap.Items)
	}
	sharedProxy := findProviderItem(t, snap.Items, "proxy", "shared")
	if sharedProxy.VehicleType != "file" || sharedProxy.Count != 2 || sharedProxy.Updatable || !sharedProxy.Replaceable || sharedProxy.UpdatedAt <= 0 {
		t.Fatalf("unexpected shared proxy provider: %+v", sharedProxy)
	}
	sharedRule := findProviderItem(t, snap.Items, "rule", "shared")
	if sharedRule.VehicleType != "file" || sharedRule.Count != 3 || sharedRule.Behavior != "domain" || sharedRule.Format != "yaml" || sharedRule.Updatable || !sharedRule.Replaceable || sharedRule.UpdatedAt <= 0 {
		t.Fatalf("unexpected shared rule provider: %+v", sharedRule)
	}
	inlineProxy := findProviderItem(t, snap.Items, "proxy", "inline-p")
	if inlineProxy.VehicleType != "inline" || inlineProxy.Count != 1 || inlineProxy.Updatable || inlineProxy.Replaceable {
		t.Fatalf("unexpected inline proxy provider: %+v", inlineProxy)
	}
	inlineRule := findProviderItem(t, snap.Items, "rule", "inline-r")
	if inlineRule.VehicleType != "inline" || inlineRule.Count != 1 || inlineRule.Updatable || inlineRule.Replaceable {
		t.Fatalf("unexpected inline rule provider: %+v", inlineRule)
	}
}

func TestProvidersUpdateAndReplaceLiveEffect(t *testing.T) {
	home := t.TempDir()
	var proxyBody atomic.Value
	var ruleBody atomic.Value
	var failServer atomic.Bool
	proxyBody.Store("proxies:\n  - { name: Remote-1, type: ss, server: 10.0.0.1, port: 8388, cipher: aes-128-gcm, password: pass }\n")
	ruleBody.Store("payload:\n  - 'old.example.test'\n")

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if failServer.Load() {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte("secret-upstream-token-leak"))
			return
		}
		switch r.URL.Path {
		case "/proxies.yaml":
			_, _ = w.Write([]byte(proxyBody.Load().(string)))
		case "/rules.yaml":
			_, _ = w.Write([]byte(ruleBody.Load().(string)))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	// 预先准备一个 MRS 规则 provider 验证二进制格式替换与拒绝。
	mrsPath := filepath.Join(home, "initial.mrs")
	var mrsBuf bytes.Buffer
	if err := RP.ConvertToMrs([]byte("initial-mrs.example.test\n"), P.Domain, P.TextRule, &mrsBuf); err != nil {
		t.Fatalf("build initial mrs: %v", err)
	}
	if err := os.WriteFile(mrsPath, mrsBuf.Bytes(), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg := fmt.Sprintf(`mode: rule
proxy-providers:
  remote-p:
    type: http
    url: %s/proxies.yaml
    path: %s/remote-p.yaml
rule-providers:
  remote-r:
    type: http
    behavior: domain
    format: yaml
    url: %s/rules.yaml
    path: %s/remote-r.yaml
  local-mrs:
    type: file
    behavior: domain
    format: mrs
    path: %s
proxy-groups:
  - name: Proxy
    type: select
    use: [remote-p]
    proxies: [DIRECT]
rules:
  - RULE-SET,remote-r,Proxy
  - RULE-SET,local-mrs,Proxy
  - MATCH,DIRECT
`, srv.URL, home, srv.URL, home, mrsPath)
	bootID, rev := providerTestStart(t, home, "p-live", cfg)

	// 1. 远程刷新 proxy-provider 和 rule-provider 并验证新节点/规则生效。
	proxyBody.Store("proxies:\n  - { name: Remote-1, type: ss, server: 10.0.0.1, port: 8388, cipher: aes-128-gcm, password: pass }\n  - { name: Remote-2, type: ss, server: 10.0.0.2, port: 8388, cipher: aes-128-gcm, password: pass }\n")
	ruleBody.Store("payload:\n  - 'fresh.example.test'\n  - 'fresh2.example.test'\n")

	rec := doJSONRequest(runtimeProviders.HandleUpdate, http.MethodPost, "/arkclash/providers/update", providers.UpdateRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "proxy", Name: "remote-p",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("update proxy provider failed: %d %s", rec.Code, rec.Body.String())
	}
	var snap providers.Snapshot
	_ = json.Unmarshal(rec.Body.Bytes(), &snap)
	item := findProviderItem(t, snap.Items, "proxy", "remote-p")
	if item.Count != 2 || item.Outcome != "updated" || item.Phase != "idle" || item.Error != "" {
		t.Fatalf("unexpected updated proxy provider: %+v", item)
	}
	if tunnel.Providers()["remote-p"].Count() != 2 {
		t.Fatalf("live proxy provider count not updated")
	}

	// 重复更新同内容返回 unchanged。
	rec = doJSONRequest(runtimeProviders.HandleUpdate, http.MethodPost, "/arkclash/providers/update", providers.UpdateRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "proxy", Name: "remote-p",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("unchanged update failed: %d %s", rec.Code, rec.Body.String())
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &snap)
	if findProviderItem(t, snap.Items, "proxy", "remote-p").Outcome != "unchanged" {
		t.Fatalf("expected unchanged outcome")
	}

	rec = doJSONRequest(runtimeProviders.HandleUpdate, http.MethodPost, "/arkclash/providers/update", providers.UpdateRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "rule", Name: "remote-r",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("update rule provider failed: %d %s", rec.Code, rec.Body.String())
	}
	rp := tunnel.RuleProviders()["remote-r"]
	if !rp.Match(&C.Metadata{Host: "fresh.example.test"}, C.RuleMatchHelper{}) {
		t.Fatal("updated rule provider did not match fresh.example.test")
	}

	// 2. 远程刷新失败不泄露上游错误且保持原有效资源。
	failServer.Store(true)
	rec = doJSONRequest(runtimeProviders.HandleUpdate, http.MethodPost, "/arkclash/providers/update", providers.UpdateRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "rule", Name: "remote-r",
	})
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "provider_update_failed") || strings.Contains(rec.Body.String(), "secret-upstream-token-leak") {
		t.Fatalf("unexpected failed update response: %d %s", rec.Code, rec.Body.String())
	}
	if !rp.Match(&C.Metadata{Host: "fresh.example.test"}, C.RuleMatchHelper{}) {
		t.Fatal("previous valid rule was lost after failed remote update")
	}

	// 3. 本地文件替换（proxy + yaml rule + mrs rule），并验证损坏文件被拒绝且保留旧资源。
	badProxyCand := filepath.Join(home, "profile-work", "bad-proxy.yaml")
	_ = os.WriteFile(badProxyCand, []byte("not: valid-proxies\n"), 0o600)
	rec = doJSONRequest(runtimeProviders.HandleReplace, http.MethodPost, "/arkclash/providers/replace", providers.ReplaceRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "proxy", Name: "remote-p", Candidate: badProxyCand,
	})
	if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "provider_invalid_content") {
		t.Fatalf("expected 422 for bad proxy candidate, got %d %s", rec.Code, rec.Body.String())
	}
	if tunnel.Providers()["remote-p"].Count() != 2 {
		t.Fatal("bad proxy replace disturbed active proxies")
	}

	goodProxyCand := filepath.Join(home, "profile-work", "good-proxy.yaml")
	_ = os.WriteFile(goodProxyCand, []byte("proxies:\n  - { name: Local-1, type: ss, server: 10.1.0.1, port: 8388, cipher: aes-128-gcm, password: pass }\n  - { name: Local-2, type: ss, server: 10.1.0.2, port: 8388, cipher: aes-128-gcm, password: pass }\n  - { name: Local-3, type: ss, server: 10.1.0.3, port: 8388, cipher: aes-128-gcm, password: pass }\n"), 0o600)
	rec = doJSONRequest(runtimeProviders.HandleReplace, http.MethodPost, "/arkclash/providers/replace", providers.ReplaceRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "proxy", Name: "remote-p", Candidate: goodProxyCand,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("good proxy replace failed: %d %s", rec.Code, rec.Body.String())
	}
	if tunnel.Providers()["remote-p"].Count() != 3 {
		t.Fatalf("expected 3 proxies after replace, got %d", tunnel.Providers()["remote-p"].Count())
	}

	// 坏 YAML 规则（即使末尾带换行也不能绕过校验！）
	badRuleCand := filepath.Join(home, "profile-work", "bad-rule.yaml")
	_ = os.WriteFile(badRuleCand, []byte("just random text\nsecond line\n"), 0o600)
	rec = doJSONRequest(runtimeProviders.HandleReplace, http.MethodPost, "/arkclash/providers/replace", providers.ReplaceRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "rule", Name: "remote-r", Candidate: badRuleCand,
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422 for bad yaml rule candidate, got %d %s", rec.Code, rec.Body.String())
	}
	if !rp.Match(&C.Metadata{Host: "fresh.example.test"}, C.RuleMatchHelper{}) {
		t.Fatal("bad rule replace disturbed active rule")
	}

	goodRuleCand := filepath.Join(home, "profile-work", "good-rule.yaml")
	_ = os.WriteFile(goodRuleCand, []byte("payload:\n  - 'replaced.example.test'\n"), 0o600)
	rec = doJSONRequest(runtimeProviders.HandleReplace, http.MethodPost, "/arkclash/providers/replace", providers.ReplaceRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "rule", Name: "remote-r", Candidate: goodRuleCand,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("good rule replace failed: %d %s", rec.Code, rec.Body.String())
	}
	if !rp.Match(&C.Metadata{Host: "replaced.example.test"}, C.RuleMatchHelper{}) || rp.Match(&C.Metadata{Host: "fresh.example.test"}, C.RuleMatchHelper{}) {
		t.Fatal("replaced yaml rule did not take effect")
	}

	// MRS 替换：错误 behavior（ipcidr 替换 domain）被拒；正确 MRS 生效。
	var wrongMrs bytes.Buffer
	if err := RP.ConvertToMrs([]byte("10.0.0.0/8\n"), P.IPCIDR, P.TextRule, &wrongMrs); err != nil {
		t.Fatal(err)
	}
	wrongMrsCand := filepath.Join(home, "profile-work", "wrong.mrs")
	_ = os.WriteFile(wrongMrsCand, wrongMrs.Bytes(), 0o600)
	rec = doJSONRequest(runtimeProviders.HandleReplace, http.MethodPost, "/arkclash/providers/replace", providers.ReplaceRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "rule", Name: "local-mrs", Candidate: wrongMrsCand,
	})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422 for wrong-behavior mrs, got %d %s", rec.Code, rec.Body.String())
	}

	var goodMrs bytes.Buffer
	if err := RP.ConvertToMrs([]byte("mrs-replaced.example.test\n"), P.Domain, P.TextRule, &goodMrs); err != nil {
		t.Fatal(err)
	}
	goodMrsCand := filepath.Join(home, "profile-work", "good.mrs")
	_ = os.WriteFile(goodMrsCand, goodMrs.Bytes(), 0o600)
	rec = doJSONRequest(runtimeProviders.HandleReplace, http.MethodPost, "/arkclash/providers/replace", providers.ReplaceRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "rule", Name: "local-mrs", Candidate: goodMrsCand,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("good mrs replace failed: %d %s", rec.Code, rec.Body.String())
	}
	if !tunnel.RuleProviders()["local-mrs"].Match(&C.Metadata{Host: "mrs-replaced.example.test"}, C.RuleMatchHelper{}) {
		t.Fatal("replaced mrs rule did not take effect")
	}

	// 沙箱外路径被拒绝。
	outside := filepath.Join(t.TempDir(), "outside.yaml")
	_ = os.WriteFile(outside, []byte("payload:\n  - 'outside.example.test'\n"), 0o600)
	rec = doJSONRequest(runtimeProviders.HandleReplace, http.MethodPost, "/arkclash/providers/replace", providers.ReplaceRequest{
		BootID: bootID, ConfigRevision: rev, Kind: "rule", Name: "remote-r", Candidate: outside,
	})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for outside candidate, got %d %s", rec.Code, rec.Body.String())
	}
}

func TestProvidersMutexAndStaleConfigRejection(t *testing.T) {
	home := t.TempDir()
	entered := make(chan struct{}, 2)
	release := make(chan struct{})
	var blockProxy atomic.Bool

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/slow-proxies.yaml":
			if blockProxy.Load() {
				select {
				case entered <- struct{}{}:
				default:
				}
				<-release
			}
			_, _ = w.Write([]byte("proxies:\n  - { name: Slow-1, type: ss, server: 10.2.0.1, port: 8388, cipher: aes-128-gcm, password: pass }\n"))
		case "/fast-rules.yaml":
			_, _ = w.Write([]byte("payload:\n  - 'fast.example.test'\n"))
		}
	}))
	defer srv.Close()

	cfgA := fmt.Sprintf(`mode: rule
proxy-providers:
  same:
    type: http
    url: %s/slow-proxies.yaml
    path: %s/same-p.yaml
rule-providers:
  same:
    type: http
    behavior: domain
    format: yaml
    url: %s/fast-rules.yaml
    path: %s/same-r.yaml
proxy-groups:
  - name: Proxy
    type: select
    use: [same]
    proxies: [DIRECT]
rules:
  - RULE-SET,same,Proxy
  - MATCH,DIRECT
`, srv.URL, home, srv.URL, home)
	bootID, revA := providerTestStart(t, home, "p-a", cfgA)
	blockProxy.Store(true)

	var wg sync.WaitGroup
	var firstCode int
	var firstBody string
	wg.Add(1)
	go func() {
		defer wg.Done()
		rec := doJSONRequest(runtimeProviders.HandleUpdate, http.MethodPost, "/arkclash/providers/update", providers.UpdateRequest{
			BootID: bootID, ConfigRevision: revA, Kind: "proxy", Name: "same",
		})
		firstCode = rec.Code
		firstBody = rec.Body.String()
	}()

	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for first update to enter HTTP handler")
	}

	// 同名同 kind 互斥返回 409 provider_busy。
	busyRec := doJSONRequest(runtimeProviders.HandleUpdate, http.MethodPost, "/arkclash/providers/update", providers.UpdateRequest{
		BootID: bootID, ConfigRevision: revA, Kind: "proxy", Name: "same",
	})
	if busyRec.Code != http.StatusConflict || !strings.Contains(busyRec.Body.String(), "provider_busy") {
		t.Fatalf("expected provider_busy, got %d %s", busyRec.Code, busyRec.Body.String())
	}

	// 同名不同 kind（rule vs proxy）互不阻塞！
	ruleRec := doJSONRequest(runtimeProviders.HandleUpdate, http.MethodPost, "/arkclash/providers/update", providers.UpdateRequest{
		BootID: bootID, ConfigRevision: revA, Kind: "rule", Name: "same",
	})
	if ruleRec.Code != http.StatusOK {
		t.Fatalf("same-name rule provider should not be blocked by proxy provider: %d %s", ruleRec.Code, ruleRec.Body.String())
	}

	// 操作进行中切换配置 -> configRevision 前进 -> 放行旧请求必须返回 provider_stale_config 且不污染新快照。
	cfgBPath := filepath.Join(home, "profiles", "p-b.yaml")
	cfgB := `mode: rule
proxies:
  - { name: Only-B, type: ss, server: 10.3.0.1, port: 8388, cipher: aes-128-gcm, password: pass }
proxy-groups:
  - name: Proxy
    type: select
    proxies: [Only-B, DIRECT]
rules:
  - MATCH,Proxy
`
	if err := os.WriteFile(cfgBPath, []byte(cfgB), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := reload(cfgBPath, "p-b", nil); err != nil {
		t.Fatalf("reload to p-b: %v", err)
	}
	close(release)
	wg.Wait()

	if firstCode != http.StatusConflict || !strings.Contains(firstBody, "provider_stale_config") {
		t.Fatalf("expected stale config rejection after reload, got %d %s", firstCode, firstBody)
	}
	snapRec := doJSONRequest(runtimeProviders.HandleList, http.MethodGet, "/arkclash/providers", nil)
	var snap providers.Snapshot
	_ = json.Unmarshal(snapRec.Body.Bytes(), &snap)
	if snap.Profile != "p-b" || snap.ConfigRevision == revA || len(snap.Items) != 0 {
		t.Fatalf("new config provider snapshot was polluted: %+v", snap)
	}
}

func TestProxyDefinitionByIdentityAndCollision(t *testing.T) {
	home := t.TempDir()
	provA := filepath.Join(home, "prov-a.yaml")
	provB := filepath.Join(home, "prov-b.yaml")
	if err := os.WriteFile(provA, []byte(`proxies:
  - name: HK-01
    type: vless
    server: hk-a.example.test
    port: 443
    uuid: 11111111-1111-1111-1111-111111111111
    tls: true
    network: grpc
    servername: a.sni.example.test
    grpc-opts:
      grpc-service-name: svc-a
`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(provB, []byte(`proxies:
  - name: HK-01
    type: trojan
    server: hk-b.example.test
    port: 8443
    password: trojan-b-password
    sni: b.sni.example.test
    network: ws
    ws-opts:
      path: /ws-b
      headers:
        Host: b.cdn.example.test
`), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := fmt.Sprintf(`mode: rule
proxies:
  - name: Direct-WS
    type: vmess
    server: direct.example.test
    port: 443
    uuid: 22222222-2222-2222-2222-222222222222
    alterId: 0
    cipher: auto
    tls: true
    servername: direct.sni.example.test
    network: ws
    ws-opts:
      path: /direct
      headers:
        Host: direct.cdn.example.test
proxy-providers:
  prov-a:
    type: file
    path: %s
    override:
      tfo: true
  prov-b:
    type: file
    path: %s
proxy-groups:
  - name: Proxy
    type: select
    proxies: [Direct-WS, DIRECT]
    use: [prov-a, prov-b]
rules:
  - MATCH,Proxy
`, provA, provB)
	bootID, rev := providerTestStart(t, home, "p-def", cfg)

	snap, err := captureProxySnapshot()
	if err != nil {
		t.Fatalf("capture snapshot: %v", err)
	}
	members := snap.Members["Proxy"]
	var directID, hkAID, hkBID, directBuiltinID string
	for _, m := range members {
		switch {
		case m.Name == "Direct-WS":
			directID = m.ID
		case m.Name == "HK-01" && m.Provider == "prov-a":
			hkAID = m.ID
		case m.Name == "HK-01" && m.Provider == "prov-b":
			hkBID = m.ID
		case m.Name == "DIRECT":
			directBuiltinID = m.ID
		}
	}
	if directID == "" || hkAID == "" || hkBID == "" || directBuiltinID == "" || hkAID == hkBID {
		t.Fatalf("unexpected members: %+v", members)
	}

	// 1. 直接定义节点（带 WS 传输参数）
	rec := doJSONRequest(postProxyDefinition, http.MethodPost, "/arkclash/proxies/definition", proxyDefinitionRequest{
		BootID: bootID, ConfigRevision: rev, ID: directID, Group: "Proxy",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("direct definition failed: %d %s", rec.Code, rec.Body.String())
	}
	var res proxyDefinitionResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
		t.Fatal(err)
	}
	if res.Name != "Direct-WS" || res.Provider != "" || res.Definition["server"] != "direct.example.test" {
		t.Fatalf("unexpected direct definition: %+v", res)
	}
	wsOpts, _ := res.Definition["ws-opts"].(map[string]any)
	if wsOpts["path"] != "/direct" {
		t.Fatalf("missing ws-opts in direct definition: %+v", res.Definition)
	}
	if errCode := validateLocalProxy(res.Definition); errCode != "" {
		t.Fatalf("exported direct definition failed local proxy validation: %s", errCode)
	}

	// 2. 跨 Provider 同名节点 HK-01 (prov-a vs prov-b) 按 id 精确区分且保留各自协议/传输/override 参数！
	recA := doJSONRequest(postProxyDefinition, http.MethodPost, "/arkclash/proxies/definition", proxyDefinitionRequest{
		BootID: bootID, ConfigRevision: rev, ID: hkAID, Group: "Proxy",
	})
	if recA.Code != http.StatusOK {
		t.Fatalf("prov-a definition failed: %d %s", recA.Code, recA.Body.String())
	}
	var resA proxyDefinitionResponse
	_ = json.Unmarshal(recA.Body.Bytes(), &resA)
	if resA.Provider != "prov-a" || resA.Definition["type"] != "vless" || resA.Definition["server"] != "hk-a.example.test" || resA.Definition["tfo"] != true {
		t.Fatalf("unexpected prov-a HK-01 definition: %+v", resA)
	}
	grpcOpts, _ := resA.Definition["grpc-opts"].(map[string]any)
	if grpcOpts["grpc-service-name"] != "svc-a" {
		t.Fatalf("missing grpc-opts in prov-a definition: %+v", resA.Definition)
	}
	if errCode := validateLocalProxy(resA.Definition); errCode != "" {
		t.Fatalf("exported prov-a definition failed local proxy validation: %s", errCode)
	}

	recB := doJSONRequest(postProxyDefinition, http.MethodPost, "/arkclash/proxies/definition", proxyDefinitionRequest{
		BootID: bootID, ConfigRevision: rev, ID: hkBID, Group: "Proxy",
	})
	if recB.Code != http.StatusOK {
		t.Fatalf("prov-b definition failed: %d %s", recB.Code, recB.Body.String())
	}
	var resB proxyDefinitionResponse
	_ = json.Unmarshal(recB.Body.Bytes(), &resB)
	if resB.Provider != "prov-b" || resB.Definition["type"] != "trojan" || resB.Definition["server"] != "hk-b.example.test" {
		t.Fatalf("unexpected prov-b HK-01 definition: %+v", resB)
	}
	wsOptsB, _ := resB.Definition["ws-opts"].(map[string]any)
	if wsOptsB["path"] != "/ws-b" {
		t.Fatalf("missing ws-opts in prov-b definition: %+v", resB.Definition)
	}
	if errCode := validateLocalProxy(resB.Definition); errCode != "" {
		t.Fatalf("exported prov-b definition failed local proxy validation: %s", errCode)
	}

	// 3. 策略组、内置节点、过期配置版本均被拒绝。
	groupRec := doJSONRequest(postProxyDefinition, http.MethodPost, "/arkclash/proxies/definition", proxyDefinitionRequest{
		BootID: bootID, ConfigRevision: rev, ID: snap.Proxies["Proxy"].ID, Group: "",
	})
	if groupRec.Code != http.StatusBadRequest || !strings.Contains(groupRec.Body.String(), "proxy_not_exportable") {
		t.Fatalf("expected proxy_not_exportable for group, got %d %s", groupRec.Code, groupRec.Body.String())
	}
	builtinRec := doJSONRequest(postProxyDefinition, http.MethodPost, "/arkclash/proxies/definition", proxyDefinitionRequest{
		BootID: bootID, ConfigRevision: rev, ID: directBuiltinID, Group: "Proxy",
	})
	if builtinRec.Code != http.StatusBadRequest || !strings.Contains(builtinRec.Body.String(), "proxy_not_exportable") {
		t.Fatalf("expected proxy_not_exportable for DIRECT, got %d %s", builtinRec.Code, builtinRec.Body.String())
	}
	staleRec := doJSONRequest(postProxyDefinition, http.MethodPost, "/arkclash/proxies/definition", proxyDefinitionRequest{
		BootID: bootID, ConfigRevision: rev + 1, ID: directID, Group: "Proxy",
	})
	if staleRec.Code != http.StatusConflict || !strings.Contains(staleRec.Body.String(), "proxy_stale_config") {
		t.Fatalf("expected proxy_stale_config, got %d %s", staleRec.Code, staleRec.Body.String())
	}
}
