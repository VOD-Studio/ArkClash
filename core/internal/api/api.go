// Package api 负责 /arkclash/* 控制面路由装配、跨进程存储锁中间件与 HTTP 编解码，不持有核心锁。
package api

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/VOD-Studio/ArkClash/core/internal/backup"
	corecfg "github.com/VOD-Studio/ArkClash/core/internal/config"
	"github.com/VOD-Studio/ArkClash/core/internal/ctrl"
	"github.com/VOD-Studio/ArkClash/core/internal/engine"
	"github.com/VOD-Studio/ArkClash/core/internal/geo"
	"github.com/VOD-Studio/ArkClash/core/internal/probe"
	"github.com/VOD-Studio/ArkClash/core/internal/subfetch"
	"github.com/metacubex/chi"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	"github.com/metacubex/mihomo/hub/route"
)

// Server 持有控制面路由所需的引擎实例与无锁探测处理器。
type Server struct {
	eng   *engine.Engine
	probe *probe.Handler
}

var (
	installOnce     sync.Once
	installedServer atomic.Pointer[Server]
)

// New 构造与给定引擎实例绑定的控制面路由装配器，可用于测试独立路由器。
func New(eng *engine.Engine) *Server {
	return &Server{
		eng: eng,
		probe: probe.NewHandler(func() probe.RuntimeToken {
			running, bootID, revision, routeToken, routeRevision := eng.ObserveProbe()
			return probe.RuntimeToken{
				Running:       running,
				BootID:        bootID,
				Revision:      revision,
				RouteToken:    routeToken,
				RouteRevision: routeRevision,
			}
		}),
	}
}

// InstallOnce 在进程生命周期内最多向 mihomo 全局路由列表注册一次 /arkclash 挂载回调并开启 EmbedMode，
// 防止连续 Start/Stop 或多次测试调用导致 chi 重复挂载 /arkclash 触发 panic。
func InstallOnce(eng *engine.Engine) *Server {
	srv := New(eng)
	installedServer.Store(srv)
	installOnce.Do(func() {
		// 关掉 mihomo 给独立进程用的接口：PUT/PATCH /configs 会绕过 applyOverrides，
		// /restart 会 exec 宿主进程，/upgrade 会下载替换内核（ADR-0009）。
		route.SetEmbedMode(true)
		route.Register(func(r chi.Router) {
			if active := installedServer.Load(); active != nil {
				active.Mount(r)
			}
		})
	})
	return srv
}

// ProbeHandler 暴露探测处理器，供测试检查执行槽占用与释放。
func (s *Server) ProbeHandler() *probe.Handler {
	return s.probe
}

func (s *Server) subfetchView() subfetch.RuntimeView {
	running, homeDir, forward, stillCurrent := s.eng.ObserveSubfetch()
	return subfetch.RuntimeView{
		Running:      running,
		HomeDir:      homeDir,
		Forward:      forward,
		StillCurrent: stillCurrent,
	}
}

// Mount 将全部 /arkclash/* 路由显式挂载到给定 chi.Router。
func (s *Server) Mount(r chi.Router) {
	r.Route("/arkclash", func(r chi.Router) {
		r.Get("/status", s.getStatus)
		r.Get("/proxies", s.getProxySnapshot)
		r.Post("/proxies/definition", s.postProxyDefinition)
		r.Post("/proxies/tailscale-login", s.postTailscaleLogin)
		s.eng.Providers().RegisterRoutes(r)
		r.Get("/selections", s.getSelections)
		r.Post("/selection", s.portableMutation(s.postSelection))
		r.Get("/delay", s.getDelay)
		r.Post("/probe", s.probe.ServeHTTP)
		r.Post("/backup/dav", s.postBackupDAV)
		r.Post("/backup/apply", s.withPortableMutation(s.postBackupApply, true))
		r.Patch("/configs", s.patchRuntimeOptions)
		r.Post("/reload", s.postReload)
		r.Post("/prefetch", s.postPrefetch)
		r.Get("/events", ctrl.GetEvents)
		geo.RegisterRoutes(r, s.eng.GeoManager, s.eng.ApplyGeoSettings)
		r.Post("/dns/settings", s.portableMutation(s.postDNSOverrides))
		r.Post("/general/settings", s.portableMutation(s.postGeneralSettings))
		r.Post("/rules/settings", s.portableMutation(s.postAddedRules))
		r.Post("/rule-sets", s.postRuleSet)
		r.Post("/scripts/apply", s.postProfileScript)
		r.Get("/scripts/outbounds", s.getScriptOutbounds)
		r.Get("/profiles/preview", s.getProfilePreview)
		r.Post("/local-proxies/{operation}", s.postLocalProxies)
		r.Post("/proxy-filters/validate", s.postProxyFilterValidation)
		s.eng.Diagnostics().RegisterRoutes(r)
		r.Post("/profiles/{name}", ctrl.ForwardCommand)
		r.Post("/vpn/connect", ctrl.ForwardCommand)
		r.Post("/vpn/disconnect", ctrl.ForwardCommand)
	})
}

func (s *Server) portableMutation(next http.HandlerFunc) http.HandlerFunc {
	return s.withPortableMutation(next, false)
}

func (s *Server) withPortableMutation(next http.HandlerFunc, restore bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if status, err := s.eng.WithPortableMutation(restore, func() { next(w, r) }); err != nil {
			ctrl.WriteError(w, r, status, err)
		}
	}
}

func (s *Server) getStatus(w http.ResponseWriter, r *http.Request) {
	status := s.eng.Status()
	if status == nil {
		ctrl.WriteError(w, r, http.StatusServiceUnavailable, errors.New("core_initializing"))
		return
	}
	render.JSON(w, r, status)
}

type runtimeOptionsBody struct {
	Mode     *string `json:"mode"`
	AllowLan *bool   `json:"allow-lan"`
}

func (s *Server) patchRuntimeOptions(w http.ResponseWriter, r *http.Request) {
	var body runtimeOptionsBody
	if err := render.DecodeJSON(r.Body, &body); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, err)
		return
	}
	if err := s.eng.SetRuntimeOptions(body.Mode, body.AllowLan); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, err)
		return
	}
	render.NoContent(w, r)
}

type reloadBody struct {
	Profile         string  `json:"profile"`
	Path            string  `json:"path"`
	ExpectedProfile *string `json:"expectedProfile,omitempty"`
}

func (s *Server) postReload(w http.ResponseWriter, r *http.Request) {
	var body reloadBody
	if err := render.DecodeJSON(r.Body, &body); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, err)
		return
	}
	if err := s.eng.Reload(body.Path, body.Profile, body.ExpectedProfile); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, err)
		return
	}
	render.NoContent(w, r)
}

type prefetchBody struct {
	Path string `json:"path"`
}

type PrefetchResult struct {
	Downloaded int    `json:"downloaded"`
	Error      string `json:"error,omitempty"`
}

func (s *Server) postPrefetch(w http.ResponseWriter, r *http.Request) {
	var body prefetchBody
	if err := render.DecodeJSON(r.Body, &body); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, err)
		return
	}
	n, err := subfetch.Prefetch(body.Path, s.subfetchView)
	if err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, err)
		return
	}
	render.JSON(w, r, PrefetchResult{Downloaded: n})
}

func (s *Server) getProxySnapshot(w http.ResponseWriter, r *http.Request) {
	snapshot, err := s.eng.CaptureProxySnapshot()
	if err != nil {
		ctrl.WriteError(w, r, http.StatusConflict, err)
		return
	}
	render.JSON(w, r, snapshot)
}

func (s *Server) postProxyDefinition(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 32<<10)
	var body engine.ProxyDefinitionRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, errors.New("proxy_invalid_request"))
		return
	}
	result, status, err := s.eng.LookupProxyDefinition(body)
	if err != nil {
		ctrl.WriteError(w, r, status, err)
		return
	}
	render.JSON(w, r, result)
}

func (s *Server) postTailscaleLogin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	var req engine.ProxyDefinitionRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<10)).Decode(&req); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, errors.New("proxy_invalid_request"))
		return
	}
	result, code, err := s.eng.RequestTailscaleLogin(r.Context(), req)
	if err != nil {
		ctrl.WriteError(w, r, code, err)
		return
	}
	render.JSON(w, r, result)
}

func (s *Server) postSelection(w http.ResponseWriter, r *http.Request) {
	var request engine.SelectionRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&request); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, errors.New("invalid_selection"))
		return
	}
	result, err := s.eng.CommitSelection(request)
	if err != nil {
		ctrl.WriteError(w, r, http.StatusConflict, err)
		return
	}
	render.JSON(w, r, result)
}

func (s *Server) getSelections(w http.ResponseWriter, r *http.Request) {
	res, status, err := s.eng.GetSelections()
	if err != nil {
		ctrl.WriteError(w, r, status, err)
		return
	}
	render.JSON(w, r, res)
}

func (s *Server) getDelay(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	delay, status, err := s.eng.MeasureDelay(r.Context(), engine.DelayRequest{
		Profile:          query.Get("profile"),
		ID:               query.Get("id"),
		Group:            query.Get("group"),
		URL:              query.Get("url"),
		TimeoutText:      query.Get("timeout"),
		ExpectedBootID:   query.Get("expectedBootId"),
		ExpectedRevision: query.Get("expectedRevision"),
	})
	if r.Context().Err() != nil {
		return
	}
	if err != nil {
		ctrl.WriteError(w, r, status, err)
		return
	}
	render.JSON(w, r, struct {
		Delay uint16 `json:"delay"`
	}{Delay: delay})
}

func (s *Server) postBackupDAV(w http.ResponseWriter, r *http.Request) {
	var req engine.BackupDAVRequest
	if err := corecfg.DecodeSettings(r.Body, &req); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, backup.ErrDAVSettings)
		return
	}
	if status, err := s.eng.RunBackupDAV(r.Context(), req); err != nil {
		ctrl.WriteError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func (s *Server) postBackupApply(w http.ResponseWriter, r *http.Request) {
	var req engine.BackupApplyRequest
	if err := corecfg.DecodeSettings(r.Body, &req); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, backup.ErrInvalid)
		return
	}
	if err := s.eng.ApplyBackup(req); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, errors.New("backup_apply"))
		return
	}
	render.NoContent(w, r)
}

func (s *Server) postDNSOverrides(w http.ResponseWriter, r *http.Request) {
	var request corecfg.DNSOverrideRequest
	if err := corecfg.DecodeSettings(r.Body, &request); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, corecfg.ErrDNSInvalid)
		return
	}
	if err := s.eng.UpdateDNSOverrides(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrDNSConflict) {
			status = http.StatusConflict
		}
		ctrl.WriteError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func (s *Server) postGeneralSettings(w http.ResponseWriter, r *http.Request) {
	var request corecfg.SettingsRequest[corecfg.GeneralSettings]
	if corecfg.DecodeSettings(r.Body, &request) != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, corecfg.ErrGeneralInvalid)
		return
	}
	if err := s.eng.UpdateGeneralSettings(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrGeneralConflict) || errors.Is(err, corecfg.ErrGeneralPort) || errors.Is(err, corecfg.ErrGeneralPanel) {
			status = http.StatusConflict
		}
		ctrl.WriteError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func (s *Server) postAddedRules(w http.ResponseWriter, r *http.Request) {
	var request corecfg.SettingsRequest[corecfg.AddedRulesSettings]
	if err := corecfg.DecodeSettings(r.Body, &request); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, err)
		return
	}
	if err := s.eng.UpdateAddedRules(request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrSettingsConflict) {
			status = http.StatusConflict
		}
		ctrl.WriteError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func (s *Server) postRuleSet(w http.ResponseWriter, r *http.Request) {
	var request corecfg.RuleSetRequest
	if err := corecfg.DecodeSettings(r.Body, &request); err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, corecfg.ErrRuleSetInput)
		return
	}
	unlock, ok := s.eng.TryLockRuleSetMutation()
	if !ok {
		ctrl.WriteError(w, r, http.StatusConflict, corecfg.ErrSettingsConflict)
		return
	}
	defer unlock()
	if err := s.eng.ChangeRuleSet(r.Context(), request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrSettingsConflict) || errors.Is(err, corecfg.ErrRuleSetInUse) {
			status = http.StatusConflict
		}
		ctrl.WriteError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func (s *Server) postProfileScript(w http.ResponseWriter, r *http.Request) {
	var request corecfg.ScriptApplyRequest
	if err := corecfg.DecodeSettings(r.Body, &request); err != nil || request.Profile == "" || request.BootID == "" {
		ctrl.WriteError(w, r, http.StatusBadRequest, corecfg.ErrScriptConflict)
		return
	}
	if err := s.eng.ApplyProfileScript(r.Context(), request); err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, corecfg.ErrScriptConflict) || errors.Is(err, corecfg.ErrSettingsConflict) {
			status = http.StatusConflict
		}
		ctrl.WriteError(w, r, status, err)
		return
	}
	render.NoContent(w, r)
}

func (s *Server) getScriptOutbounds(w http.ResponseWriter, r *http.Request) {
	profile := r.URL.Query().Get("profile")
	if !corecfg.ValidProfileID(profile) {
		ctrl.WriteError(w, r, http.StatusBadRequest, corecfg.ErrScriptConflict)
		return
	}
	view := s.eng.View()
	if view == nil || !view.Status.Running {
		ctrl.WriteError(w, r, http.StatusServiceUnavailable, corecfg.ErrScriptConflict)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	outbounds, err := corecfg.ReadScriptOutbounds(ctx, view.HomeDir, profile)
	if err != nil {
		ctrl.WriteError(w, r, http.StatusBadRequest, err)
		return
	}
	render.JSON(w, r, outbounds)
}

func (s *Server) getProfilePreview(w http.ResponseWriter, r *http.Request) {
	profile := r.URL.Query().Get("profile")
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	response, status, err := s.eng.BuildProfilePreview(ctx, profile)
	if err != nil {
		ctrl.WriteError(w, r, status, err)
		return
	}
	render.JSON(w, r, response)
}

func (s *Server) postLocalProxies(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, corecfg.LocalProxyLimit)
	var body corecfg.LocalProxyBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil ||
		len(body.Definitions) > corecfg.LocalProxyCount || len(body.Lines) > corecfg.LocalProxyCount {
		ctrl.WriteError(w, r, http.StatusBadRequest, corecfg.ErrLocalProxyInput)
		return
	}
	switch chi.URLParam(r, "operation") {
	case "validate":
		render.JSON(w, r, corecfg.ValidateLocalProxies(body.Definitions))
	case "encode":
		render.JSON(w, r, corecfg.EncodeLocalProxies(body.Definitions))
	case "decode":
		results, err := corecfg.DecodeLocalProxies(body.Lines)
		if err != nil {
			ctrl.WriteError(w, r, http.StatusBadRequest, err)
			return
		}
		render.JSON(w, r, results)
	default:
		http.NotFound(w, r)
	}
}

func (s *Server) postProxyFilterValidation(w http.ResponseWriter, r *http.Request) {
	var body corecfg.ProxyFilterRequest
	if err := corecfg.DecodeSettings(http.MaxBytesReader(w, r.Body, 8<<10), &body); err != nil ||
		!corecfg.ValidProxyFilterExpression(body.Expression) {
		ctrl.WriteError(w, r, http.StatusBadRequest, corecfg.ErrSettingsInvalid)
		return
	}
	render.JSON(w, r, corecfg.ProxyFilterResult{InvalidPart: corecfg.InvalidProxyFilterPart(body.Expression)})
}
