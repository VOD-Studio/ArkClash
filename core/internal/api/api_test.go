package api

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/engine"
	"github.com/VOD-Studio/ArkClash/core/internal/geo"
	"github.com/metacubex/chi"
	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	LC "github.com/metacubex/mihomo/listener/config"
	"golang.org/x/sys/unix"
)

const apiLifecycleProfile = `mode: direct
log-level: silent
proxy-groups:
  - name: Manual
    type: select
    proxies: [DIRECT, REJECT]
rules: ['MATCH,DIRECT']
`

type stubTunHandle struct{ fd int }

func (h *stubTunHandle) Close() error { return nil }

var (
	testEng *engine.Engine
	testSrv *Server
)

func TestMain(m *testing.M) {
	testEng = engine.New()
	testEng.SetTunFactory(func(options LC.Tun) (engine.TunHandle, error) {
		return &stubTunHandle{fd: options.FileDescriptor}, nil
	})
	testSrv = InstallOnce(testEng)
	os.Exit(m.Run())
}

func apiLifecycleOptions(t *testing.T) corecfg.StartOptions {
	t.Helper()
	home := t.TempDir()
	if err := os.Mkdir(filepath.Join(home, "profiles"), 0o700); err != nil {
		t.Fatal(err)
	}
	reserved, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := reserved.Addr().String()
	if err := reserved.Close(); err != nil {
		t.Fatal(err)
	}
	return corecfg.StartOptions{HomeDir: home, Controller: address, Geo: geo.DefaultSettings()}
}

func apiWriteProfile(t *testing.T, opts corecfg.StartOptions, name, content string) string {
	t.Helper()
	path := filepath.Join(opts.HomeDir, "profiles", name+".yaml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestAPIMountIsolationAndPortableMutationConflict(t *testing.T) {
	opts := apiLifecycleOptions(t)
	opts.Profile = "mount"
	opts.ConfigPath = apiWriteProfile(t, opts, opts.Profile, apiLifecycleProfile)
	if err := testEng.Start(opts); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = testEng.Stop() })

	// 独立构造路由器并显式 Mount，验证不依赖全局 init() 与 mihomo 路由列表。
	router := chi.NewRouter()
	New(testEng).Mount(router)

	statusRec := httptest.NewRecorder()
	router.ServeHTTP(statusRec, httptest.NewRequest(http.MethodGet, "/arkclash/status", nil))
	if statusRec.Code != http.StatusOK || !strings.Contains(statusRec.Body.String(), `"running":true`) {
		t.Fatalf("mounted /arkclash/status=%d %s", statusRec.Code, statusRec.Body.String())
	}

	filterRec := httptest.NewRecorder()
	router.ServeHTTP(filterRec, httptest.NewRequest(http.MethodPost, "/arkclash/proxy-filters/validate",
		strings.NewReader(`{"expression":"(?i)hk"}`)))
	if filterRec.Code != http.StatusOK || !strings.Contains(filterRec.Body.String(), `"invalidPart":0`) {
		t.Fatalf("mounted /arkclash/proxy-filters/validate=%d %s", filterRec.Code, filterRec.Body.String())
	}

	// 模拟外部进程持有配置存储锁，写入路由必须返回 409。
	lockFile, err := os.OpenFile(filepath.Join(opts.HomeDir, ".profile-storage.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := unix.Flock(int(lockFile.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		_ = lockFile.Close()
		t.Fatal(err)
	}
	lockedRec := httptest.NewRecorder()
	router.ServeHTTP(lockedRec, httptest.NewRequest(http.MethodPost, "/arkclash/selection", strings.NewReader(`{}`)))
	_ = lockFile.Close()
	if lockedRec.Code != http.StatusConflict {
		t.Fatalf("locked portableMutation=%d, want 409", lockedRec.Code)
	}

	// 模拟存储代次前进后未重载，写入路由必须返回 409。
	if err := os.WriteFile(filepath.Join(opts.HomeDir, "profiles", backup.StoreMarker), []byte("newer-gen"), 0o600); err != nil {
		t.Fatal(err)
	}
	staleRec := httptest.NewRecorder()
	router.ServeHTTP(staleRec, httptest.NewRequest(http.MethodPost, "/arkclash/selection", strings.NewReader(`{}`)))
	if staleRec.Code != http.StatusConflict {
		t.Fatalf("stale generation portableMutation=%d, want 409", staleRec.Code)
	}
}
