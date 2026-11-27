package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/log"
	"golang.org/x/sys/unix"
)

func portableDataPath(home, name string) string { return backup.DataPath(home, name) }
func portableGeneration(home string) string     { return backup.Generation(home) }

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

func portableMutation(next http.HandlerFunc) http.HandlerFunc {
	return withPortableMutation(next, false)
}

func withPortableMutation(next http.HandlerFunc, restore bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		view := eng.View()
		home := ""
		if view != nil {
			home = view.HomeDir
		}
		if home == "" {
			writeError(w, r, http.StatusServiceUnavailable, backup.ErrIO)
			return
		}
		unlock, err := lockPortableStorage(home)
		if err != nil {
			writeError(w, r, http.StatusConflict, backup.ErrChanged)
			return
		}
		defer unlock()
		latest := eng.View()
		upToDate := latest != nil && latest.HomeDir == home && latest.StoreGeneration == portableGeneration(home)
		if !restore && !upToDate {
			writeError(w, r, http.StatusConflict, backup.ErrChanged)
			return
		}
		next(w, r)
	}
}

type backupDAVRequest struct {
	BootID string             `json:"bootId"`
	Work   string             `json:"work"`
	Action string             `json:"action"`
	DAV    backup.DAVSettings `json:"dav"`
}

var backupDAVBusy atomic.Bool

func postBackupDAV(w http.ResponseWriter, r *http.Request) {
	var req backupDAVRequest
	if err := decodeProfileSettings(r.Body, &req); err != nil {
		writeError(w, r, http.StatusBadRequest, backup.ErrDAVSettings)
		return
	}
	if !backupDAVBusy.CompareAndSwap(false, true) {
		writeError(w, r, http.StatusConflict, backup.ErrChanged)
		return
	}
	defer backupDAVBusy.Store(false)
	view := eng.View()
	if view == nil || !view.Status.Running || view.Status.BootID != req.BootID {
		writeError(w, r, http.StatusConflict, backup.ErrChanged)
		return
	}
	home := view.HomeDir
	status := &view.Status
	file, err := backup.WorkspaceArchive(home, req.Work)
	if err == nil {
		ctx, stop := ruleRequestContext(r.Context(), nil)
		defer stop()
		transport := backup.DirectTransport()
		if status.Forward == "running" {
			transport, err = newRuleTransport()
			if err == nil {
				transport.ResponseHeaderTimeout = 60 * time.Second
			}
		}
		if err == nil {
			defer transport.CloseIdleConnections()
			err = backup.DAV(ctx, transport, req.DAV, req.Action, file)
		} else {
			err = backup.ErrDAVNetwork
		}
	}
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	render.NoContent(w, r)
}

type backupApplyRequest struct {
	BootID   string `json:"bootId"`
	Profile  string `json:"profile"`
	Revision string `json:"revision"`
	Mode     string `json:"mode"`
	AllowLan *bool  `json:"allowLan"`
}

func postBackupApply(w http.ResponseWriter, r *http.Request) {
	var req backupApplyRequest
	if err := decodeProfileSettings(r.Body, &req); err != nil {
		writeError(w, r, http.StatusBadRequest, backup.ErrInvalid)
		return
	}
	if err := applyBackup(req); err != nil {
		writeError(w, r, http.StatusBadRequest, errors.New("backup_apply"))
		return
	}
	render.NoContent(w, r)
}

func applyBackup(req backupApplyRequest) error {
	return eng.withState(func(tx *stateTx) error {
		if !eng.running || req.BootID != eng.bootID ||
			(req.Profile != "" && (!addedRulesProfileID.MatchString(req.Profile) || filepath.Base(req.Profile) != req.Profile)) {
			return backup.ErrChanged
		}
		if req.Profile == "" && (eng.tun != nil || eng.vpnCreated || businessListenersOpen()) {
			return backup.ErrChanged
		}
		var list struct {
			Current  string `json:"current"`
			Revision string `json:"revision"`
		}
		if file, err := os.Open(filepath.Join(eng.current.HomeDir, "profiles", "list.json")); err != nil {
			return err
		} else {
			err := json.NewDecoder(file).Decode(&list)
			_ = file.Close()
			if err != nil || req.Profile != list.Current || req.Revision != list.Revision {
				return backup.ErrChanged
			}
		}
		next := eng.current
		next.StoreGeneration = portableGeneration(next.HomeDir)
		next.Mode, next.AllowLan = req.Mode, req.AllowLan
		next.Profile, next.ConfigPath = req.Profile, ""
		if req.Profile != "" {
			next.ConfigPath = filepath.Join(eng.current.HomeDir, "profiles", req.Profile+".yaml")
		}
		var err error
		for _, read := range []func() error{
			func() error { next.Geo, err = readGeoSettings(next.HomeDir); return err },
			func() error { next.DNS, err = readDNSOverrides(next.HomeDir); return err },
			func() error { next.General, err = readGeneralSettings(next.HomeDir); return err },
			func() error { next.AddedRules, err = readAddedRules(next.HomeDir); return err },
			func() error { next.RuleSets, err = readRuleSets(next.HomeDir); return err },
			func() error { return loadProfileExtension(&next) },
		} {
			if err := read(); err != nil {
				return err
			}
		}
		var inbound inboundSettings
		cfg, err := parseConfigWithInboundHash(next.ConfigPath, &next, &inbound)
		if err != nil {
			return err
		}
		_, err = tx.CommitReload(reloadPlan{Next: next, Cfg: cfg, Inbound: inbound})
		if err == nil {
			if panelErr := setPanelControllerLocked(next.General.ControllerSecret); panelErr != nil {
				log.Warnln("[ArkClash] external controller port unavailable")
			}
			if manager := activeGeo.Load(); manager != nil {
				err = manager.applySettingsLocked(next.Geo)
			}
			eng.publishRuntimeLocked()
		}
		return err
	})
}
