package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/tunnel"
)

const scriptProfile = `mode: rule
proxies:
  - name: 香港
    type: vless
    server: example.test
    port: 443
    reality-opts:
      short-id: 00
proxy-groups:
  - name: 测试
    type: select
    proxies: [香港, DIRECT]
rules:
  - MATCH,测试
`

func TestScriptModeTransformsFullRawConfigBeforeOverrides(t *testing.T) {
	selection := profileScript{identity: "script:example:r1", source: `const main = async config => {
		if (config.proxies[0]['reality-opts']['short-id'] !== '00' || config['proxy-groups'][0].name !== '测试' ||
			!config['proxy-providers'] || config.rule !== undefined || config.rules[0] !== 'MATCH,测试') throw Error('invalid');
		return { ...config, 'external-controller': '0.0.0.0:8888', secret: 'fake', tun: { enable: true, 'auto-route': true },
		  'find-process-mode': 'always', profile: { 'store-selected': true }, mode: 'global', 'allow-lan': true,
		  rules: ['DOMAIN-SUFFIX,example.test,DIRECT', ...config.rules] };
	}`}
	raw, err := scriptRawConfig(t.Context(), []byte(scriptProfile), selection)
	if err != nil {
		t.Fatal(err)
	}
	allowLan := false
	opts := startOptions{Script: selection, Profile: "p1", Controller: "127.0.0.1:19090", Secret: "local", Mode: "direct",
		AllowLan: &allowLan, AddedRules: addedRulesSettings{Rules: []addedRule{{Kind: "DOMAIN", Payload: "ignored.test", Target: "REJECT"}}}}
	applyOverrides(raw, opts)
	if !reflect.DeepEqual(raw.Rule, []string{"DOMAIN-SUFFIX,example.test,DIRECT", "MATCH,测试"}) {
		t.Fatalf("unexpected rules: %v", raw.Rule)
	}
	if raw.Tun.Enable || raw.Tun.AutoRoute || raw.Profile.StoreSelected || raw.FindProcessMode != process.FindProcessOff ||
		raw.ExternalController != opts.Controller || raw.Secret != opts.Secret || raw.Mode.String() != "direct" || raw.AllowLan {
		t.Fatal("platform overrides were not enforced")
	}
}

func TestScriptBindingsArePerProfileAndMissingIsExplicit(t *testing.T) {
	home := t.TempDir()
	if _, err := readProfileScript(home, "original"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(home, "profiles"), 0700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(home, "profiles", "scripts.json")
	contents := `{"version":1,"scripts":[{"id":"one","revision":"r1","source":"const main = c => c"}],"bindings":[
		{"profile":"a","mode":"script","scriptId":"one"},{"profile":"b","mode":"standard","scriptId":"one"},
		{"profile":"c","mode":"script","scriptId":"missing"},{"profile":"d","mode":"script","scriptId":""}]}`
	if err := os.WriteFile(file, []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
	for profile, identity := range map[string]string{"a": "script:one:r1", "b": "", "d": "script", "legacy": ""} {
		selection, err := readProfileScript(home, profile)
		if err != nil || selection.identity != identity {
			t.Fatalf("%s: %+v %v", profile, selection, err)
		}
	}
	if _, err := readProfileScript(home, "c"); !errors.Is(err, errScriptMissing) {
		t.Fatalf("missing script should be recoverable: %v", err)
	}
}

func TestScriptFailureCannotAdvanceRuntime(t *testing.T) {
	home := t.TempDir()
	if err := os.Mkdir(filepath.Join(home, "profiles"), 0700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(home, "profiles", "a.yaml")
	if err := os.WriteFile(file, []byte(scriptProfile), 0600); err != nil {
		t.Fatal(err)
	}
	contents := `{"version":1,"scripts":[{"id":"one","revision":"broken","source":"const main = () => { throw 1 }"}],
		"bindings":[{"profile":"a","mode":"script","scriptId":"one"}]}`
	if err := os.WriteFile(filepath.Join(home, "profiles", "scripts.json"), []byte(contents), 0600); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	previous, wasRunning, boot, revision := current, running, runtimeBootID, runtimeConfigRevision
	current, running, runtimeBootID, runtimeConfigRevision = startOptions{HomeDir: home, Profile: "a", ConfigPath: file}, true, "scripts-test", 27
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		current, running, runtimeBootID, runtimeConfigRevision = previous, wasRunning, boot, revision
		mu.Unlock()
	})
	if err := applyProfileScript(context.Background(), scriptApplyRequest{
		BootID: "scripts-test", Profile: "a", Identity: "script:one:broken",
	}); err == nil {
		t.Fatal("broken script was applied")
	}
	if runtimeConfigRevision != 27 || current.Script.enabled() {
		t.Fatal("failed script altered applied identity")
	}
}

func TestScriptApplyAndCorrectionPreserveTunAndRoutes(t *testing.T) {
	opts := lifecycleOptions(t)
	opts.Profile = "script-smoke"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, opts.Profile, "mode: rule\nlog-level: silent\nrules: ['MATCH,DIRECT']\n")
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500, DNSHijacking: true}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	before := runtimeSnapshot.Load()
	active := tunListener
	save := func(revision, source string) string {
		t.Helper()
		data, err := json.Marshal(scriptStore{Version: 1, Scripts: []scriptRecord{{ID: "one", Revision: revision, Source: source}},
			Bindings: []scriptBinding{{Profile: opts.Profile, Mode: "script", ScriptID: "one"}}})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(opts.HomeDir, "profiles", "scripts.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
		return "script:one:" + revision
	}
	apply := func(identity string) error {
		return applyProfileScript(t.Context(), scriptApplyRequest{BootID: before.BootID, Profile: opts.Profile, Identity: identity})
	}
	good := save("good", `const main = async c => ({ ...await Promise.resolve(c), rules: ['DOMAIN,example.test,REJECT', ...c.rules] })`)
	if err := apply(good); err != nil {
		t.Fatal(err)
	}
	applied := runtimeSnapshot.Load()
	if got := tunnel.Rules(); len(got) != 2 || got[0].Adapter() != "REJECT" || applied.ProfileExtension != good ||
		applied.ConfigRevision != before.ConfigRevision+1 || applied.BootID != before.BootID || tunListener != active {
		t.Fatal("valid transform did not publish the new rules using the existing TUN")
	}
	if err := apply(good); err != nil || runtimeSnapshot.Load().ConfigRevision != applied.ConfigRevision {
		t.Fatalf("reapplying the same revision reloaded the runtime: %v", err)
	}
	broken := save("broken", `const main = () => { throw new Error('synthetic') }`)
	if err := apply(broken); err == nil || runtimeSnapshot.Load().ProfileExtension != good ||
		runtimeSnapshot.Load().ConfigRevision != applied.ConfigRevision || tunListener != active || len(tunnel.Rules()) != 2 {
		t.Fatalf("broken draft disturbed the running routes: %v", err)
	}
	repaired := save("repaired", `const main = c => ({...c, rules: ['MATCH,REJECT'] })`)
	if err := apply(repaired); err != nil || runtimeSnapshot.Load().ProfileExtension != repaired ||
		len(tunnel.Rules()) != 1 || tunListener != active {
		t.Fatalf("corrected revision could not be applied: %v", err)
	}
}
