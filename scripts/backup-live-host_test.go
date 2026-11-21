package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	"github.com/metacubex/mihomo/tunnel"
)

func TestBackupApplyKeepsAttachedTunAndUsesRestoredRevision(t *testing.T) {
	opts := lifecycleOptions(t)
	opts.Profile = "first"
	opts.ConfigPath = lifecycleWriteProfile(t, opts, opts.Profile,
		"mode: rule\nlog-level: silent\nrules: ['MATCH,DIRECT']\n")
	if err := start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = stop() })
	if err := attachTun(11, tunNetworkOptions{Stack: "gvisor", MTU: 1500}, hostAttachIdentity()); err != nil {
		t.Fatal(err)
	}
	before, originalTun := runtimeSnapshot.Load(), tunListener
	dir := filepath.Join(opts.HomeDir, "profiles")
	for name, body := range map[string]string{
		backup.StoreMarker:      "restored",
		"list.json":             `{"version":1,"current":"first","revision":"restored"}`,
		"first.yaml":            "mode: rule\nlog-level: silent\nrules: ['MATCH,REJECT']\n",
		"general-settings.json": `{"revision":"restored-general","controllerSecret":"restored-panel-secret","delayTimeout":8000,"logLevel":"error"}`,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	req := backupApplyRequest{BootID: before.BootID, Profile: "first", Revision: "previous", Mode: "rule"}
	if err := applyBackup(req); !errors.Is(err, backup.ErrChanged) {
		t.Fatalf("过期代次应用结果 %v", err)
	}
	req.Revision = "restored"
	if err := applyBackup(req); err != nil {
		t.Fatal(err)
	}
	after := runtimeSnapshot.Load()
	if after.BootID != before.BootID || after.ConfigRevision != before.ConfigRevision+1 || tunListener != originalTun ||
		tunnel.Rules()[0].Adapter() != "REJECT" || current.StoreGeneration != "restored" ||
		activePanel == nil || activePanel.secret != "restored-panel-secret" {
		t.Fatalf("应用恢复配置后，内核或 TUN 未保留预期状态 %+v", after)
	}
}
