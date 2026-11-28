package engine

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/ruletunnel"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/log"
	"golang.org/x/sys/unix"
)

func lockPortableStorage(home string) (func(), error) {
	lock, err := os.OpenFile(filepath.Join(home, ".profile-storage.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		lock.Close()
		return nil, err
	}
	return func() { _ = lock.Close() }, nil
}

// WithPortableMutation 在跨进程配置存储锁下执行写入并复核存储代次，
// 同时供内部 /arkclash/* API 与 9090 外部面板复用，避免 api <-> engine 环依赖。
func (e *Engine) WithPortableMutation(restore bool, fn func()) (int, error) {
	view := e.View()
	home := ""
	if view != nil {
		home = view.HomeDir
	}
	if home == "" {
		return http.StatusServiceUnavailable, backup.ErrIO
	}
	unlock, err := lockPortableStorage(home)
	if err != nil {
		return http.StatusConflict, backup.ErrChanged
	}
	defer unlock()
	latest := e.View()
	upToDate := latest != nil && latest.HomeDir == home && latest.StoreGeneration == backup.Generation(home)
	if !restore && !upToDate {
		return http.StatusConflict, backup.ErrChanged
	}
	fn()
	return http.StatusOK, nil
}

type BackupDAVRequest struct {
	BootID string             `json:"bootId"`
	Work   string             `json:"work"`
	Action string             `json:"action"`
	DAV    backup.DAVSettings `json:"dav"`
}

func (e *Engine) RunBackupDAV(ctx context.Context, req BackupDAVRequest) (int, error) {
	if !e.backupDAVBusy.CompareAndSwap(false, true) {
		return http.StatusConflict, backup.ErrChanged
	}
	defer e.backupDAVBusy.Store(false)
	view := e.View()
	if view == nil || !view.Status.Running || view.Status.BootID != req.BootID {
		return http.StatusConflict, backup.ErrChanged
	}
	home := view.HomeDir
	status := &view.Status
	file, err := backup.WorkspaceArchive(home, req.Work)
	if err == nil {
		reqCtx, stop := ruletunnel.RequestContext(ctx, nil)
		defer stop()
		transport := backup.DirectTransport()
		if status.Forward == "running" {
			transport, err = ruletunnel.NewTransport()
			if err == nil {
				transport.ResponseHeaderTimeout = 60 * time.Second
			}
		}
		if err == nil {
			defer transport.CloseIdleConnections()
			err = backup.DAV(reqCtx, transport, req.DAV, req.Action, file)
		} else {
			err = backup.ErrDAVNetwork
		}
	}
	if err != nil {
		return http.StatusBadRequest, err
	}
	return http.StatusNoContent, nil
}

type BackupApplyRequest struct {
	BootID   string `json:"bootId"`
	Profile  string `json:"profile"`
	Revision string `json:"revision"`
	Mode     string `json:"mode"`
	AllowLan *bool  `json:"allowLan"`
}

func (e *Engine) ApplyBackup(req BackupApplyRequest) error {
	return e.withState(func(tx *stateTx) error {
		if !e.running || req.BootID != e.bootID ||
			(req.Profile != "" && (!corecfg.ValidProfileID(req.Profile) || filepath.Base(req.Profile) != req.Profile)) {
			return backup.ErrChanged
		}
		if req.Profile == "" && (e.tun != nil || e.vpnCreated || businessListenersOpen()) {
			return backup.ErrChanged
		}
		var list struct {
			Current  string `json:"current"`
			Revision string `json:"revision"`
		}
		if file, err := os.Open(filepath.Join(e.current.HomeDir, "profiles", "list.json")); err != nil {
			return err
		} else {
			err := json.NewDecoder(file).Decode(&list)
			_ = file.Close()
			if err != nil || req.Profile != list.Current || req.Revision != list.Revision {
				return backup.ErrChanged
			}
		}
		next := e.current
		next.Mode, next.AllowLan = req.Mode, req.AllowLan
		next.Profile, next.ConfigPath = req.Profile, ""
		if req.Profile != "" {
			next.ConfigPath = filepath.Join(e.current.HomeDir, "profiles", req.Profile+".yaml")
		}
		if err := corecfg.LoadAll(&next); err != nil {
			return err
		}
		var inbound inboundSettings
		cfg, err := parseConfigWithInboundHash(next.ConfigPath, &next, &inbound)
		if err != nil {
			return err
		}
		_, err = tx.CommitReload(reloadPlan{Next: next, Cfg: cfg, Inbound: inbound})
		if err == nil {
			if panelErr := e.setPanelControllerLocked(next.General.ControllerSecret); panelErr != nil {
				log.Warnln("[ArkClash] external controller port unavailable")
			}
			if manager := e.geo.Load(); manager != nil {
				err = manager.ApplySettings(next.Geo)
			}
			e.publishRuntimeLocked()
		}
		return err
	})
}
