package api

import (
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/VOD-Studio/ArkClash/core/internal/subfetch"
)

func TestFetchAndPrefetchPathCheckConcurrentWithReload(t *testing.T) {
	options := apiLifecycleOptions(t)
	firstPath := apiWriteProfile(t, options, "one", apiLifecycleProfile)
	secondPath := apiWriteProfile(t, options, "two", apiLifecycleProfile)
	options.Profile = "one"
	options.ConfigPath = firstPath
	if err := testEng.Start(options); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := testEng.Stop(); err != nil {
			t.Fatal(err)
		}
	})

	outsidePath := filepath.Join(t.TempDir(), "escape.yaml")
	if err := os.WriteFile(outsidePath, []byte(apiLifecycleProfile), 0o600); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	wg.Add(3)
	go func() {
		defer wg.Done()
		for i := range 8 {
			path, name := secondPath, "two"
			if i%2 == 1 {
				path, name = firstPath, "one"
			}
			if err := testEng.Reload(path, name, nil); err != nil {
				t.Errorf("reload %d: %v", i, err)
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		for range 20 {
			if _, err := subfetch.Prefetch(outsidePath, testSrv.subfetchView); err == nil || err.Error() != "invalid_profile_path" {
				t.Errorf("prefetch outside path=%v, want invalid_profile_path", err)
				return
			}
			if n, err := subfetch.Prefetch(firstPath, testSrv.subfetchView); err != nil || n != 0 {
				t.Errorf("prefetch valid path: n=%d err=%v", n, err)
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		for range 20 {
			res := subfetch.Fetch(subfetch.Request{URL: "http://127.0.0.1:1/sub", Path: outsidePath}, testSrv.subfetchView)
			if res.Error != "invalid_profile_path" {
				t.Errorf("fetch outside path=%+v, want invalid_profile_path", res)
				return
			}
		}
	}()
	wg.Wait()
}
