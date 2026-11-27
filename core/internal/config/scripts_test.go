package config

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/component/process"
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
	selection := ProfileScript{Identity: "script:example:r1", Source: `const main = async config => {
		if (config.proxies[0]['reality-opts']['short-id'] !== '00' || config['proxy-groups'][0].name !== '测试' ||
			!config['proxy-providers'] || config.rule !== undefined || config.rules[0] !== 'MATCH,测试') throw Error('invalid');
		return { ...config, 'external-controller': '0.0.0.0:8888', secret: 'fake', tun: { enable: true, 'auto-route': true },
		  'find-process-mode': 'always', profile: { 'store-selected': true }, mode: 'global', 'allow-lan': true,
		  rules: ['DOMAIN-SUFFIX,example.test,DIRECT', ...config.rules] };
	}`}
	raw, err := ScriptRawConfig(t.Context(), []byte(scriptProfile), selection)
	if err != nil {
		t.Fatal(err)
	}
	allowLan := false
	opts := StartOptions{Script: selection, Profile: "p1", Controller: "127.0.0.1:19090", Secret: "local", Mode: "direct",
		AllowLan: &allowLan, AddedRules: AddedRulesSettings{Rules: []AddedRule{{Kind: "DOMAIN", Payload: "ignored.test", Target: "REJECT"}}}}
	ApplyOverrides(raw, opts)
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
	if _, err := ReadProfileScript(home, "original"); err != nil {
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
		selection, err := ReadProfileScript(home, profile)
		if err != nil || selection.Identity != identity {
			t.Fatalf("%s: %+v %v", profile, selection, err)
		}
	}
	if _, err := ReadProfileScript(home, "c"); !errors.Is(err, ErrScriptMissing) {
		t.Fatalf("missing script should be recoverable: %v", err)
	}
}
