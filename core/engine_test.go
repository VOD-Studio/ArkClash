package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEngineWithStateUnlocksAndRunsPostUnlockOnPanic(t *testing.T) {
	fixture(t)
	postRan := false
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("expected panic to propagate")
			}
		}()
		_ = eng.withState(func(tx *stateTx) error {
			tx.deferUnlock(func() {
				// 验证 postUnlock 运行时 eng.mu 已经释放，可安全重新加锁。
				eng.mu.Lock()
				postRan = true
				eng.mu.Unlock()
			})
			panic("boom")
		})
	}()
	if !postRan {
		t.Fatal("postUnlock did not run after panic")
	}
	if !eng.mu.TryLock() {
		t.Fatal("eng.mu remained locked after panic")
	}
	eng.mu.Unlock()
}

func TestEngineRunningProfileMatchesStatusOnFailurePaths(t *testing.T) {
	assertSynced := func(stage string) {
		t.Helper()
		profile, ok := runningProfile()
		status := eng.Status()
		if status == nil {
			if ok || profile != "" {
				t.Fatalf("%s: runningProfile=(%q,%v), status=nil", stage, profile, ok)
			}
			return
		}
		if ok != status.Running || (ok && profile != status.Profile) || (!ok && profile != "") {
			t.Fatalf("%s: runningProfile=(%q,%v), status=(%q,%v)", stage, profile, ok, status.Profile, status.Running)
		}
	}

	options := lifecycleOptions(t)
	// 1. start 阶段读取无效配置失败。
	badPath := lifecycleWriteProfile(t, options, "bad", "rules: [\n")
	badOpts := options
	badOpts.Profile = "bad"
	badOpts.ConfigPath = badPath
	if err := start(badOpts); err == nil {
		t.Fatal("expected invalid profile start to fail")
	}
	assertSynced("start invalid config")

	// 2. start 阶段 Geo 设置校验失败（newGeoManager 失败回滚）。
	validPath := lifecycleWriteProfile(t, options, "good", lifecycleProfile)
	if err := os.WriteFile(filepath.Join(options.HomeDir, "geo-settings.json"), []byte(`{"version":1,"revision":"bad","autoUpdate":true,"intervalHours":0}`), 0o600); err != nil {
		t.Fatal(err)
	}
	geoFailOpts := options
	geoFailOpts.Profile = "good"
	geoFailOpts.ConfigPath = validPath
	if err := start(geoFailOpts); err == nil {
		t.Fatal("expected invalid geo-settings start to fail")
	}
	assertSynced("start invalid geo settings")
	_ = os.Remove(filepath.Join(options.HomeDir, "geo-settings.json"))

	// 3. 正常启动后注入 reload 失败与 attachTun 失败，runningProfile 均与 status 一致。
	goodOpts := options
	goodOpts.Profile = "good"
	goodOpts.ConfigPath = validPath
	if err := start(goodOpts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := stop(); err != nil {
			t.Fatal(err)
		}
	})
	assertSynced("after start")

	if err := reload(badPath, "bad", new("good")); err == nil {
		t.Fatal("expected invalid reload to fail")
	}
	assertSynced("after failed reload")

	hostTunStartError = os.ErrPermission
	status := eng.Status()
	if err := attachTun(7, tunNetworkOptions{Stack: "gvisor", MTU: 1500}, attachIdentity{
		BootID: status.BootID, Profile: status.Profile, ConfigRevision: status.ConfigRevision,
	}); err == nil {
		t.Fatal("expected attachTun failure")
	}
	hostTunStartError = nil
	assertSynced("after failed attachTun")
}

func TestEngineViewReflectsSettingsUpdates(t *testing.T) {
	options := lifecycleOptions(t)
	validPath := lifecycleWriteProfile(t, options, "view", lifecycleProfile)
	options.Profile = "view"
	options.ConfigPath = validPath
	if err := start(options); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := stop(); err != nil {
			t.Fatal(err)
		}
	})

	view := eng.View()
	if view == nil || view.HomeDir != options.HomeDir || view.CaptureLogs || view.DelayTimeout != 8000 {
		t.Fatalf("unexpected initial view: %+v", view)
	}
	if err := updateGeneralSettings(profileSettingsRequest[generalSettings]{
		BootID:           view.Status.BootID,
		ExpectedRevision: "default",
		Settings: generalSettings{
			Revision:     "rev-1",
			DelayTimeout: 5000,
			LogLevel:     "info",
			CaptureLogs:  true,
		},
	}); err != nil {
		t.Fatal(err)
	}
	updated := eng.View()
	if !updated.CaptureLogs || updated.DelayTimeout != 5000 {
		t.Fatalf("view did not update after general settings: %+v", updated)
	}
}
