package backup

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func fixture(t *testing.T, current string, names ...string) string {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, "profiles")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	profiles := []map[string]any{}
	for _, name := range names {
		profiles = append(profiles, map[string]any{"id": name, "name": name, "nameEdited": true, "subscription": ""})
		place(t, dir, name+".yaml", "proxies: []\n")
		place(t, dir, name+".selected.json", `{"Group":"DIRECT"}`)
	}
	list := object{}
	assign(list, "version", 1)
	assign(list, "current", current)
	assign(list, "profiles", profiles)
	assign(list, "subscriptions", []object{})
	if err := writeObject(dir, "list.json", list); err != nil {
		t.Fatal(err)
	}
	place(t, home, "dns-overrides.json", `{"revision":"source","entries":{}}`)
	place(t, home, "runtime.json", "exclude")
	return home
}

func place(t *testing.T, root, name, data string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, name), []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
}

func snapshot(t *testing.T, root, work, name string) string {
	t.Helper()
	target := filepath.Join(work, name)
	if _, err := Snapshot(root, target, true); err != nil {
		t.Fatal(err)
	}
	return target
}

func TestArchiveManifestContract(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "testdata", "contracts.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		BackupManifest json.RawMessage
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	input := t.TempDir()
	const yaml = "proxies: []\n"
	place(t, input, "fixture.yaml", yaml)
	work := t.TempDir()
	target := filepath.Join(work, "fixture.zip")
	if err := Pack(input, target, "9007199254740993"); err != nil {
		t.Fatal(err)
	}
	archive, err := zip.OpenReader(target)
	if err != nil {
		t.Fatal(err)
	}
	defer archive.Close()
	file, err := archive.Open("manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	actual, err := io.ReadAll(file)
	if err = errors.Join(err, file.Close()); err != nil {
		t.Fatal(err)
	}
	want, err := json.Marshal(fixture.BackupManifest)
	if err != nil {
		t.Fatal(err)
	}
	if string(actual) != string(want) {
		t.Fatalf("归档清单不一致\n实际：%s\n预期：%s", actual, want)
	}
}

func TestArchiveRestoreMatrix(t *testing.T) {
	for _, tc := range []struct {
		name             string
		all, replace     bool
		current, dns     string
		profiles, remove int
	}{
		{"profiles merge", false, false, "local", "local", 3, 0},
		{"profiles replace", false, true, "new", "local", 2, 1},
		{"all merge", true, false, "new", "archive", 3, 0},
		{"all replace", true, true, "new", "archive", 2, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			work := t.TempDir()
			local := fixture(t, "local", "local", "same")
			source := fixture(t, "new", "new", "same")
			place(t, filepath.Join(source, "profiles"), "same.yaml", "proxies: []\nrules: []\n")
			place(t, local, "dns-overrides.json", `{"revision":"local"}`)
			place(t, source, "dns-overrides.json", `{"revision":"archive"}`)
			place(t, local, "backup-settings.json", `{"policy":"replace"}`)
			archive := filepath.Join(work, "test.zip")
			if err := Pack(snapshot(t, source, work, "source"), archive, "fixture"); err != nil {
				t.Fatal(err)
			}
			in := filepath.Join(work, "import")
			if err := Unpack(archive, in); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(filepath.Join(in, "runtime.json")); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("归档包含运行状态")
			}
			previous := snapshot(t, local, work, "previous")
			target := filepath.Join(work, "target")
			plan, err := Plan(previous, in, target, tc.all, tc.replace)
			if err != nil || plan.Current != tc.current || plan.Profiles != tc.profiles || plan.Removed != tc.remove {
				t.Fatalf("恢复计划 %+v, %v", plan, err)
			}
			settings, err := readObject(target, "dns-overrides.json")
			if err != nil || str(settings, "revision") != map[bool]string{true: plan.Revision, false: tc.dns}[tc.all] {
				t.Fatalf("恢复范围错误 %v", err)
			}
			if _, err := os.Stat(filepath.Join(target, "backup-settings.json")); err != nil {
				t.Fatal(err)
			}
			staged, _ := os.ReadFile(filepath.Join(target, "same.yaml"))
			if !strings.Contains(string(staged), "rules:") {
				t.Fatal("同 ID 源内容未更新")
			}
			if err := PrepareCommit(local, previous, filepath.Join(work, "fresh")); err != nil {
				t.Fatal(err)
			}
			if err := Seal(target, plan.Revision); err != nil {
				t.Fatal(err)
			}
			if runtime.GOOS == "linux" {
				if err := Commit(local, target); err != nil {
					t.Fatal(err)
				}
				list, err := readObject(filepath.Join(local, "profiles"), "list.json")
				if err != nil || str(list, "current") != tc.current || !InStore(local) {
					t.Fatalf("配置库没有切换 %v", err)
				}
			}
		})
	}
}

func TestEmptyArchiveAndConflict(t *testing.T) {
	work := t.TempDir()
	local := fixture(t, "local", "local")
	previous := snapshot(t, local, work, "previous")
	empty := snapshot(t, fixture(t, ""), work, "empty")
	target := filepath.Join(work, "target")
	plan, err := Plan(previous, empty, target, false, true)
	if err != nil || plan.Changes || plan.Removed != 0 || plan.Current != "local" {
		t.Fatalf("空包改变配置库 %+v %v", plan, err)
	}
	updated := filepath.Join(local, "replacement")
	place(t, local, "replacement", "proxies: []\nrules: []\n")
	if err := os.Rename(updated, filepath.Join(local, "profiles", "local.yaml")); err != nil {
		t.Fatal(err)
	}
	if err := PrepareCommit(local, previous, filepath.Join(work, "fresh")); !errors.Is(err, ErrChanged) {
		t.Fatalf("没有检测同 ID 内容变化 %v", err)
	}
}

func TestRejectUnsafeZIP(t *testing.T) {
	for _, name := range []string{"../escape.yaml", "/tmp/escape.yaml", "list.json", "alias.yaml"} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			file, err := os.Create(filepath.Join(dir, "bad.zip"))
			if err != nil {
				t.Fatal(err)
			}
			w := zip.NewWriter(file)
			for i := 0; i < 2; i++ {
				entry := &zip.FileHeader{Name: name}
				if name == "alias.yaml" {
					entry.SetMode(os.ModeSymlink | 0777)
				}
				dst, err := w.CreateHeader(entry)
				if err != nil {
					t.Fatal(err)
				}
				_, _ = io.WriteString(dst, "data")
			}
			if err := errors.Join(w.Close(), file.Close()); err != nil {
				t.Fatal(err)
			}
			if err := Unpack(file.Name(), filepath.Join(dir, "target")); !errors.Is(err, ErrInvalid) {
				t.Fatalf("恶意路径或重复条目被接受 %v", err)
			}
		})
	}
}

func TestDAVProtocol(t *testing.T) {
	work := t.TempDir()
	place(t, work, "source.zip", "archive")
	source := filepath.Join(work, "source.zip")
	download := filepath.Join(work, "target.zip")
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PUT" || r.Header.Get("Authorization") != "" {
			t.Error("重定向修改了方法或传递了凭据")
		}
		bytes, err := io.ReadAll(r.Body)
		if err != nil || string(bytes) != "archive" || r.Header.Get("Content-Type") != "application/octet-stream" {
			t.Error("重定向请求未保留内容")
		}
		w.WriteHeader(http.StatusCreated)
	}))
	defer other.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case "OPTIONS":
			if !strings.HasPrefix(r.Header.Get("Authorization"), "Digest ") {
				w.Header().Set("WWW-Authenticate", `Digest realm="backup", nonce="test", qop="auth", algorithm=MD5`)
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if !strings.Contains(r.Header.Get("Authorization"), `uri="/dav%20root"`) {
				t.Error("Digest 未使用原始路径")
			}
			w.WriteHeader(http.StatusNoContent)
		case "MKCOL":
			w.WriteHeader(http.StatusMethodNotAllowed)
		case "PUT":
			if r.URL.EscapedPath() != "/dav%20root/ArkClash/my%20file.zip" {
				t.Error("远程文件路径不正确")
			}
			w.Header().Set("Location", other.URL+"/archive")
			w.WriteHeader(http.StatusSeeOther)
		case "GET":
			if strings.HasSuffix(r.URL.Path, "partial.zip") {
				w.Header().Set("Content-Range", "bytes 1-6/7")
			} else {
				w.Header().Set("Content-Range", "bytes 0-6/7")
			}
			w.WriteHeader(http.StatusPartialContent)
			_, _ = io.WriteString(w, "archive")
		}
	}))
	defer server.Close()
	settings := DAVSettings{server.URL + "/dav%20root", "test", "pw", "my file.zip"}
	transport := DirectTransport()
	for _, operation := range []struct{ action, name string }{{"probe", ""}, {"upload", source}, {"download", download}} {
		if err := DAV(context.Background(), transport, settings, operation.action, operation.name); err != nil {
			t.Fatalf("%s: %v", operation.action, err)
		}
	}
	if data, err := os.ReadFile(download); err != nil || string(data) != "archive" {
		t.Fatalf("文件读取失败 %v", err)
	}
	settings.FileName = "partial.zip"
	if err := DAV(context.Background(), transport, settings, "download", filepath.Join(work, "partial.zip")); !errors.Is(err, ErrDAVResponse) {
		t.Fatalf("接受了不完整的 206 %v", err)
	}
}
