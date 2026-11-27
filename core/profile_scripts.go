package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/script"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

func getScriptOutbounds(w http.ResponseWriter, r *http.Request) {
	profile := r.URL.Query().Get("profile")
	if !corecfg.ValidProfileID(profile) {
		writeError(w, r, http.StatusBadRequest, corecfg.ErrScriptConflict)
		return
	}
	view := eng.View()
	if view == nil || !view.Status.Running {
		writeError(w, r, http.StatusServiceUnavailable, corecfg.ErrScriptConflict)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	outbounds, err := corecfg.ReadScriptOutbounds(ctx, view.HomeDir, profile)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	render.JSON(w, r, outbounds)
}

func postProfileScript(w http.ResponseWriter, r *http.Request) {
	var request corecfg.ScriptApplyRequest
	if err := corecfg.DecodeSettings(r.Body, &request); err != nil || request.Profile == "" || request.BootID == "" {
		writeError(w, r, http.StatusBadRequest, corecfg.ErrScriptConflict)
		return
	}
	if err := applyProfileScript(r.Context(), request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrScriptConflict) || errors.Is(err, corecfg.ErrSettingsConflict) {
			status = http.StatusConflict
		}
		writeError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func applyProfileScript(ctx context.Context, request corecfg.ScriptApplyRequest) error {
	var (
		next     corecfg.StartOptions
		revision uint64
		conflict bool
	)
	_ = eng.withState(func(tx *stateTx) error {
		if !eng.running || eng.bootID != request.BootID || eng.current.Profile != request.Profile || eng.current.CustomRules || eng.cleanupFailure != nil {
			conflict = true
			return nil
		}
		next, revision = eng.current, eng.configRevision
		return nil
	})
	if conflict {
		return corecfg.ErrScriptConflict
	}

	selection, err := corecfg.ReadProfileScript(next.HomeDir, request.Profile)
	if err != nil {
		return err
	}
	if selection.Identity != request.Identity {
		return corecfg.ErrScriptConflict
	}
	standard, err := request.SelectedRules(next)
	if err != nil {
		return err
	}
	if next.Script.Identity == selection.Identity && next.ProfileRules.Revision == standard.Revision {
		return nil
	}
	next.Script = selection
	path := next.ConfigPath
	raw, hash, err := corecfg.BuildRawConfigWithHash(ctx, path, next)
	if errors.Is(err, os.ErrNotExist) {
		// 更新成功后，候选文件已原子改名成配置的固定路径。
		path = filepath.Join(next.HomeDir, "profiles", request.Profile+".yaml")
		raw, hash, err = corecfg.BuildRawConfigWithHash(ctx, path, next)
	}
	if err != nil {
		if scriptError := new(script.Error); errors.As(err, &scriptError) {
			return scriptError
		}
		return corecfg.ErrScriptConfig
	}

	return eng.withState(func(tx *stateTx) error {
		if ctx.Err() != nil || !eng.running || eng.bootID != request.BootID || revision != eng.configRevision || eng.cleanupFailure != nil {
			return corecfg.ErrScriptConflict
		}
		latest, err := corecfg.ReadProfileScript(next.HomeDir, request.Profile)
		if err != nil || latest.Identity != selection.Identity {
			return corecfg.ErrScriptConflict
		}
		standard, err = request.SelectedRules(eng.current)
		if err != nil {
			return err
		}
		// 模式和局域网开关可以在脚本执行时变化，但不会增加配置版本。
		next = eng.current
		next.ConfigPath, next.Script, next.ContentHash = path, selection, hash
		next.ProfileRules = standard
		var inbounds inboundSettings
		cfg, err := prepareRawConfig(raw, next, &inbounds)
		if err != nil {
			if errors.Is(err, corecfg.ErrAddedRulesMatchTarget) || errors.Is(err, corecfg.ErrDNSProxyServersRequired) {
				return err
			}
			if !selection.Enabled() {
				return corecfg.ErrSettingsInvalid
			}
			return corecfg.ErrScriptConfig
		}
		if eng.tun != nil && !dnsListenerAvailable(inbounds.dnsListen, inbounds.dnsMark) {
			return corecfg.ErrScriptConfig
		}
		if _, err := tx.CommitReload(reloadPlan{Next: next, Cfg: cfg, Inbound: inbounds}); err != nil {
			return corecfg.ErrScriptApply
		}
		return nil
	})
}
