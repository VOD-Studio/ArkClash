package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"go.yaml.in/yaml/v3"
)

const previewSyntheticProfile = `mode: rule
allow-lan: true
external-controller: 0.0.0.0:9999
secret: sub-secret
find-process-mode: always
profile:
  store-selected: true
tun:
  enable: true
  auto-route: true
proxies:
  - name: 香港-01
    type: vless
    server: hk.example.test
    port: 443
    uuid: 11111111-1111-1111-1111-111111111111
    tls: true
    servername: hk.example.test
  - name: 日本-01
    type: ss
    server: jp.example.test
    port: 8388
    cipher: aes-128-gcm
    password: secret-node-password
proxy-groups:
  - name: 代理
    type: select
    proxies: [香港-01, 日本-01, DIRECT]
  - name: 媒体
    type: select
    proxies: [日本-01, DIRECT]
rules:
  - DOMAIN-SUFFIX,base.example.test,代理
  - MATCH,代理
`

const previewCustomProfile = `mode: rule
proxies:
  - name: 自建节点
    type: ss
    server: custom.example.test
    port: 8388
    cipher: aes-128-gcm
    password: custom-password
proxy-groups:
  - name: 自建组
    type: select
    proxies: [自建节点, DIRECT]
rules:
  - DOMAIN-SUFFIX,custom.example.test,自建组
  - MATCH,DIRECT
`

func writePreviewJSON(t *testing.T, path string, value any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestProfilePreviewMatchesComposedConfigAndCustomProfile(t *testing.T) {
	opts := lifecycleOptions(t)
	opts.Secret = "arkclash-internal-bearer-secret-999"
	opts.Profile = "synth"
	opts.Mode = "rule"
	allowLan := false
	opts.AllowLan = &allowLan
	synthPath := lifecycleWriteProfile(t, opts, "synth", previewSyntheticProfile)
	_ = lifecycleWriteProfile(t, opts, "custom1", previewCustomProfile)
	opts.ConfigPath = synthPath

	writePreviewJSON(t, filepath.Join(opts.HomeDir, "profiles", "list.json"), map[string]any{
		"version": 1,
		"current": "synth",
		"profiles": []map[string]any{
			{"id": "synth", "name": "合成配置", "nameEdited": true, "subscription": "", "contentRevision": "rev-synth-1", "type": "file"},
			{"id": "custom1", "name": "自定义配置", "nameEdited": true, "subscription": "", "contentRevision": "rev-custom-1", "type": "custom"},
		},
		"subscriptions": []any{},
	})

	writePreviewJSON(t, filepath.Join(opts.HomeDir, "profiles", "scripts.json"), corecfg.ScriptStore{
		Version: 1,
		Scripts: []corecfg.ScriptRecord{{
			ID:       "s1",
			Revision: "sr1",
			Source: `const main = config => ({
				...config,
				rules: ['DOMAIN,script.example.test,媒体', ...config.rules]
			})`,
		}},
		Bindings: []corecfg.ScriptBinding{
			{Profile: "synth", Mode: "script", ScriptID: "s1"},
			{Profile: "custom1", Mode: "script", ScriptID: "s1"},
		},
	})

	writePreviewJSON(t, corecfg.AddedRulesPath(opts.HomeDir), corecfg.AddedRulesSettings{
		Revision: "ar-1",
		Rules: []corecfg.AddedRule{
			{ID: "g1", Kind: "DOMAIN", Payload: "global.example.test", Target: "流媒体", CustomExit: true},
		},
		Profiles: []corecfg.ProfileAddedRules{{
			Profile:     "synth",
			Revision:    "pr-1",
			Rules:       []corecfg.AddedRule{{ID: "p1", Kind: "DOMAIN", Payload: "profile.example.test", Target: "MATCH"}},
			Disabled:    []string{},
			MatchTarget: "代理",
			ExitTargets: []corecfg.AddedRuleExit{{Name: "流媒体", Target: "媒体"}},
		}},
	})

	ipv6 := true
	servers := []string{"https://1.1.1.1/dns-query"}
	enhanced := constant.DNSFakeIP
	writePreviewJSON(t, corecfg.DNSOverridesPath(opts.HomeDir), corecfg.DNSOverrideSettings{
		Revision: "dns-1",
		Entries: corecfg.DNSOverrideEntries{
			IPv6:         &ipv6,
			Servers:      &servers,
			EnhancedMode: &enhanced,
		},
	})

	unifiedDelay := true
	tcpConcurrent := true
	coreIPv6 := false
	geodataLoader := "standard"
	writePreviewJSON(t, corecfg.GeneralSettingsPath(opts.HomeDir), corecfg.GeneralSettings{
		Revision:     "gen-1",
		DelayTimeout: 5000,
		LogLevel:     "warning",
		Ports:        &corecfg.GeneralPorts{Mixed: 7899},
		Hosts:        map[string][]string{"preview.local": {"127.0.0.1"}},
		CoreOverrides: &corecfg.GeneralCoreOverrides{
			UnifiedDelay:  &unifiedDelay,
			TCPConcurrent: &tcpConcurrent,
			IPv6:          &coreIPv6,
			GeodataLoader: &geodataLoader,
		},
	})

	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })

	// 对照同一版本的实际组合配置，确认预览包含完整节点、代理组、最终规则与强制覆写。
	preview, err := buildProfilePreview(t.Context(), "synth")
	if err != nil {
		t.Fatal(err)
	}
	if !preview.Applied || preview.Profile != "synth" || preview.ContentRevision != "rev-synth-1" ||
		preview.CustomRules || preview.ScriptIdentity != "script:s1:sr1" {
		t.Fatalf("unexpected synth preview metadata: %+v", preview)
	}
	if strings.Contains(preview.YAML, opts.Secret) {
		t.Fatal("preview leaked internal controller secret")
	}

	got := config.DefaultRawConfig()
	if err := yaml.Unmarshal([]byte(preview.YAML), got); err != nil {
		t.Fatalf("preview yaml did not unmarshal cleanly: %v", err)
	}
	eng.mu.Lock()
	expectedOpts := eng.current
	eng.mu.Unlock()
	expected, err := corecfg.BuildRawConfig(t.Context(), expectedOpts.ConfigPath, expectedOpts)
	if err != nil {
		t.Fatal(err)
	}
	if err := corecfg.ComposeRawConfig(expected, expectedOpts); err != nil {
		t.Fatal(err)
	}
	expected.Secret = ""

	if len(got.Proxy) != len(expected.Proxy) || len(got.ProxyGroup) != len(expected.ProxyGroup) {
		t.Fatalf("proxies/groups count mismatch: got (%d,%d), want (%d,%d)",
			len(got.Proxy), len(got.ProxyGroup), len(expected.Proxy), len(expected.ProxyGroup))
	}
	wantRules := []string{
		"DOMAIN,profile.example.test,代理",
		"DOMAIN,global.example.test,媒体",
		"DOMAIN,script.example.test,媒体",
		"DOMAIN-SUFFIX,base.example.test,代理",
		"MATCH,代理",
	}
	if !reflect.DeepEqual(got.Rule, wantRules) || !reflect.DeepEqual(expected.Rule, wantRules) {
		t.Fatalf("rules mismatch: got=%v expected=%v want=%v", got.Rule, expected.Rule, wantRules)
	}
	if got.Tun.Enable || got.Tun.AutoRoute || got.Profile.StoreSelected ||
		got.FindProcessMode != process.FindProcessOff || got.ExternalController != opts.Controller ||
		got.Secret != "" || got.AllowLan || got.MixedPort != 7899 || !got.DNS.Enable || !got.DNS.IPv6 ||
		!got.UnifiedDelay || !got.TCPConcurrent || got.IPv6 || got.GeodataLoader != "standard" ||
		!reflect.DeepEqual(got.DNS.NameServer, servers) {
		t.Fatalf("overrides not reflected in preview: tun=%+v profile=%+v fpm=%v ctrl=%q lan=%v port=%d dns=%+v unified=%v tcp=%v ipv6=%v loader=%q",
			got.Tun, got.Profile, got.FindProcessMode, got.ExternalController, got.AllowLan, got.MixedPort, got.DNS,
			got.UnifiedDelay, got.TCPConcurrent, got.IPv6, got.GeodataLoader)
	}

	// 结构化自定义配置跳过脚本和附加规则，仍应用 DNS、常规与平台覆写，并标记为未应用。
	customPreview, err := buildProfilePreview(t.Context(), "custom1")
	if err != nil {
		t.Fatal(err)
	}
	if customPreview.Applied || !customPreview.CustomRules || customPreview.ContentRevision != "rev-custom-1" {
		t.Fatalf("unexpected custom preview metadata: %+v", customPreview)
	}
	gotCustom := config.DefaultRawConfig()
	if err := yaml.Unmarshal([]byte(customPreview.YAML), gotCustom); err != nil {
		t.Fatal(err)
	}
	wantCustomRules := []string{"DOMAIN-SUFFIX,custom.example.test,自建组", "MATCH,DIRECT"}
	if !reflect.DeepEqual(gotCustom.Rule, wantCustomRules) {
		t.Fatalf("custom profile unexpectedly received script or added rules: %v", gotCustom.Rule)
	}
	if gotCustom.MixedPort != 7899 || !gotCustom.DNS.IPv6 || gotCustom.Tun.Enable {
		t.Fatalf("custom profile missing global overrides: port=%d dnsIPv6=%v tun=%v",
			gotCustom.MixedPort, gotCustom.DNS.IPv6, gotCustom.Tun.Enable)
	}
}

func TestProfilePreviewPreservesLiveForwardingAndSanitizesErrors(t *testing.T) {
	opts := lifecycleOptions(t)
	opts.Profile = "live"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, "live", "mode: rule\nlog-level: silent\nproxies:\n  - name: p\n    type: direct\nrules:\n  - MATCH,DIRECT\n")
	_ = lifecycleWriteProfile(t, opts, "broken-script", "mode: rule\nproxies:\n  - name: p\n    type: direct\nrules:\n  - MATCH,DIRECT\n")
	_ = lifecycleWriteProfile(t, opts, "broken-yaml", "proxies: [invalid: top-secret-password-999\n")

	writePreviewJSON(t, filepath.Join(opts.HomeDir, "profiles", "list.json"), map[string]any{
		"version": 1,
		"current": "live",
		"profiles": []map[string]any{
			{"id": "live", "name": "在线配置", "nameEdited": true, "subscription": "", "contentRevision": "r1", "type": "file"},
			{"id": "broken-script", "name": "坏脚本", "nameEdited": true, "subscription": "", "contentRevision": "r2", "type": "file"},
			{"id": "broken-yaml", "name": "坏配置", "nameEdited": true, "subscription": "", "contentRevision": "r3", "type": "file"},
		},
		"subscriptions": []any{},
	})
	writePreviewJSON(t, filepath.Join(opts.HomeDir, "profiles", "scripts.json"), corecfg.ScriptStore{
		Version: 1,
		Scripts: []corecfg.ScriptRecord{{
			ID:       "bad",
			Revision: "r-bad",
			Source:   `const main = () => { throw new Error('leaked-token-xyz'); }`,
		}},
		Bindings: []corecfg.ScriptBinding{{Profile: "broken-script", Mode: "script", ScriptID: "bad"}},
	})

	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	if err := attachTun(19, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	before := eng.Status()
	beforeTun := eng.tun
	beforeRules := len(tunnel.Rules())

	// 正常预览、脚本报错、YAML 语法错误均不能打断现有转发或推进配置版本。
	if _, err := buildProfilePreview(t.Context(), "live"); err != nil {
		t.Fatal(err)
	}
	if _, err := buildProfilePreview(t.Context(), "broken-script"); err == nil ||
		!strings.HasPrefix(err.Error(), "script_execution") || strings.Contains(err.Error(), "leaked-token-xyz") {
		t.Fatalf("script error was not sanitized: %v", err)
	}
	if _, err := buildProfilePreview(t.Context(), "broken-yaml"); err == nil ||
		err.Error() != "invalid_yaml" || strings.Contains(err.Error(), "top-secret-password-999") {
		t.Fatalf("yaml error was not sanitized: %v", err)
	}

	after := eng.Status()
	if after.BootID != before.BootID || after.ConfigRevision != before.ConfigRevision || eng.tun !=
		beforeTun || len(tunnel.Rules()) != beforeRules {
		t.Fatalf("preview disturbed live runtime: before=%+v after=%+v", before, after)
	}

	// 磁盘上修改了脚本绑定但尚未应用时，预览必须标记 applied=false。
	writePreviewJSON(t, filepath.Join(opts.HomeDir, "profiles", "scripts.json"), corecfg.ScriptStore{
		Version: 1,
		Scripts: []corecfg.ScriptRecord{{
			ID:       "ok",
			Revision: "r-ok",
			Source:   `const main = c => ({ ...c, rules: ['DOMAIN,pending.example.test,REJECT', ...c.rules] })`,
		}},
		Bindings: []corecfg.ScriptBinding{{Profile: "live", Mode: "script", ScriptID: "ok"}},
	})
	pending, err := buildProfilePreview(t.Context(), "live")
	if err != nil {
		t.Fatal(err)
	}
	if pending.Applied || !strings.Contains(pending.YAML, "pending.example.test") {
		t.Fatalf("expected unapplied preview with pending script rule: applied=%v", pending.Applied)
	}

	// HTTP 处理器在核心停止时返回 503 preview_core_unavailable。
	if err := stop(); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/arkclash/profiles/preview?profile=live", nil)
	getProfilePreview(rec, req)
	if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "preview_core_unavailable") {
		t.Fatalf("unexpected stopped response: %d %s", rec.Code, rec.Body.String())
	}
}
