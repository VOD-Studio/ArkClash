package main

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestFetchAndPrefetchPathCheckConcurrentWithReload(t *testing.T) {
	options := lifecycleOptions(t)
	firstPath := lifecycleWriteProfile(t, options, "one", lifecycleProfile)
	secondPath := lifecycleWriteProfile(t, options, "two", lifecycleProfile)
	options.Profile = "one"
	options.ConfigPath = firstPath
	if err := start(options); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := stop(); err != nil {
			t.Fatal(err)
		}
	})

	outsidePath := filepath.Join(t.TempDir(), "escape.yaml")
	if err := os.WriteFile(outsidePath, []byte(lifecycleProfile), 0o600); err != nil {
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
			if err := reload(path, name, nil); err != nil {
				t.Errorf("reload %d: %v", i, err)
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		for range 20 {
			if _, err := prefetch(outsidePath); err == nil || err.Error() != "invalid_profile_path" {
				t.Errorf("prefetch outside path=%v, want invalid_profile_path", err)
				return
			}
			if n, err := prefetch(firstPath); err != nil || n != 0 {
				t.Errorf("prefetch valid path: n=%d err=%v", n, err)
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		for range 20 {
			res := fetch(fetchRequest{URL: "http://127.0.0.1:1/sub", Path: outsidePath})
			if res.Error != "invalid_profile_path" {
				t.Errorf("fetch outside path=%+v, want invalid_profile_path", res)
				return
			}
		}
	}()
	wg.Wait()
}
