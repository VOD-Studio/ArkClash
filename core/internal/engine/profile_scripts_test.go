package engine

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
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
	eng.mu.Lock()
	previous, wasRunning, boot, revision, prevView := eng.current, eng.running, eng.bootID, eng.configRevision, eng.view.Load()
	eng.current, eng.running, eng.bootID, eng.configRevision = corecfg.StartOptions{HomeDir: home, Profile: "a", ConfigPath: file}, true, "scripts-test", 27
	eng.publishRuntimeLocked()
	eng.mu.Unlock()
	t.Cleanup(func() {
		eng.mu.Lock()
		eng.current, eng.running, eng.bootID, eng.configRevision = previous, wasRunning, boot, revision
		eng.view.Store(prevView)
		eng.mu.Unlock()
	})
	if err := applyProfileScript(context.Background(), corecfg.ScriptApplyRequest{
		BootID: "scripts-test", Profile: "a", Identity: "script:one:broken",
	}); err == nil {
		t.Fatal("broken script was applied")
	}
	if eng.configRevision != 27 || eng.current.Script.Enabled() {
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
	before := eng.Status()
	active := eng.tun
	save := func(revision, source string) string {
		t.Helper()
		data, err := json.Marshal(corecfg.ScriptStore{Version: 1, Scripts: []corecfg.ScriptRecord{{ID: "one", Revision: revision, Source: source}},
			Bindings: []corecfg.ScriptBinding{{Profile: opts.Profile, Mode: "script", ScriptID: "one"}}})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(opts.HomeDir, "profiles", "scripts.json"), data, 0600); err != nil {
			t.Fatal(err)
		}
		return "script:one:" + revision
	}
	apply := func(identity string) error {
		return applyProfileScript(t.Context(), corecfg.ScriptApplyRequest{BootID: before.BootID, Profile: opts.Profile, Identity: identity})
	}
	good := save("good", `const main = async c => ({ ...await Promise.resolve(c), rules: ['DOMAIN,example.test,REJECT', ...c.rules] })`)
	if err := apply(good); err != nil {
		t.Fatal(err)
	}
	applied := eng.Status()
	if got := tunnel.Rules(); len(got) != 2 || got[0].Adapter() != "REJECT" || applied.ProfileExtension != good ||
		applied.ConfigRevision != before.ConfigRevision+1 || applied.BootID != before.BootID || eng.tun != active {
		t.Fatal("valid transform did not publish the new rules using the existing TUN")
	}
	if err := apply(good); err != nil || eng.Status().ConfigRevision != applied.ConfigRevision {
		t.Fatalf("reapplying the same revision reloaded the runtime: %v", err)
	}
	broken := save("broken", `const main = () => { throw new Error('synthetic') }`)
	if err := apply(broken); err == nil || eng.Status().ProfileExtension != good || eng.Status().ConfigRevision != applied.ConfigRevision || eng.tun != active || len(tunnel.Rules()) != 2 {
		t.Fatalf("broken draft disturbed the running routes: %v", err)
	}
	repaired := save("repaired", `const main = c => ({...c, rules: ['MATCH,REJECT'] })`)
	if err := apply(repaired); err != nil || eng.Status().ProfileExtension != repaired ||
		len(tunnel.Rules()) != 1 || eng.tun != active {
		t.Fatalf("corrected revision could not be applied: %v", err)
	}
}
