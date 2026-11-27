package main

import (
	"bufio"
	"errors"
	"io"
	"net"

	"github.com/VOD-Studio/ArkClash/core/internal/ctrl"
	"github.com/VOD-Studio/ArkClash/core/internal/subfetch"
	"github.com/metacubex/mihomo/hub/route"

	"github.com/metacubex/chi"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)

func init() {
	// 关掉 mihomo 给独立进程用的接口：PUT/PATCH /configs 会绕过 applyOverrides，
	// /restart 会 exec 宿主进程，/upgrade 会下载替换内核（ADR-0009）。
	route.SetEmbedMode(true)
	route.Register(func(r chi.Router) {
		r.Route("/arkclash", func(r chi.Router) {
			r.Get("/status", getStatus)
			r.Get("/proxies", getProxySnapshot)
			r.Post("/proxies/definition", postProxyDefinition)
			r.Post("/proxies/tailscale-login", postTailscaleLogin)
			eng.providers.RegisterRoutes(r)
			r.Get("/selections", getSelections)
			r.Post("/selection", portableMutation(postSelection))
			r.Get("/delay", getDelay)
			r.Post("/probe", eng.probe.ServeHTTP)
			r.Post("/backup/dav", postBackupDAV)
			r.Post("/backup/apply", withPortableMutation(postBackupApply, true))
			r.Patch("/configs", patchRuntimeOptions)
			r.Post("/reload", postReload)
			r.Post("/prefetch", postPrefetch)
			r.Get("/events", ctrl.GetEvents)
			r.Get("/geo", getGeo)
			r.Post("/geo/settings", postGeoSettings)
			r.Post("/dns/settings", portableMutation(postDNSOverrides))
			r.Post("/general/settings", portableMutation(postGeneralSettings))
			r.Post("/rules/settings", portableMutation(postAddedRules))
			r.Post("/rule-sets", postRuleSet)
			r.Post("/scripts/apply", postProfileScript)
			r.Get("/scripts/outbounds", getScriptOutbounds)
			r.Get("/profiles/preview", getProfilePreview)
			r.Post("/local-proxies/{operation}", postLocalProxies)
			r.Post("/proxy-filters/validate", postProxyFilterValidation)
			r.Post("/geo/update", postGeoUpdate)
			r.Get("/geo/events", getGeoEvents)
			eng.diag.RegisterRoutes(r)
			r.Post("/profiles/{name}", ctrl.ForwardCommand)
			r.Post("/vpn/connect", ctrl.ForwardCommand)
			r.Post("/vpn/disconnect", ctrl.ForwardCommand)
		})
	})
}

func writeError(w http.ResponseWriter, r *http.Request, status int, err error) {
	ctrl.WriteError(w, r, status, err)
}

func getStatus(w http.ResponseWriter, r *http.Request) {
	status := eng.Status()
	if status == nil {
		writeError(w, r, http.StatusServiceUnavailable, errors.New("core_initializing"))
		return
	}
	render.JSON(w, r, status)
}

type runtimeOptionsBody struct {
	Mode     *string `json:"mode"`
	AllowLan *bool   `json:"allow-lan"`
}

func patchRuntimeOptions(w http.ResponseWriter, r *http.Request) {
	var body runtimeOptionsBody
	if err := render.DecodeJSON(r.Body, &body); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	if err := setRuntimeOptions(body.Mode, body.AllowLan); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	render.NoContent(w, r)
}

type reloadBody struct {
	Profile         string  `json:"profile"`
	Path            string  `json:"path"`
	ExpectedProfile *string `json:"expectedProfile,omitempty"`
}

func postReload(w http.ResponseWriter, r *http.Request) {
	var body reloadBody
	if err := render.DecodeJSON(r.Body, &body); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	if err := reload(body.Path, body.Profile, body.ExpectedProfile); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	render.NoContent(w, r)
}

type prefetchBody struct {
	Path string `json:"path"`
}

type prefetchResult struct {
	Downloaded int    `json:"downloaded"`
	Error      string `json:"error,omitempty"`
}

func postPrefetch(w http.ResponseWriter, r *http.Request) {
	var body prefetchBody
	if err := render.DecodeJSON(r.Body, &body); err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	n, err := prefetch(body.Path)
	if err != nil {
		writeError(w, r, http.StatusBadRequest, err)
		return
	}
	render.JSON(w, r, prefetchResult{Downloaded: n})
}

func upgradeWebSocket(w http.ResponseWriter, r *http.Request) (net.Conn, *bufio.ReadWriter, error) {
	return ctrl.UpgradeWebSocket(w, r)
}

func writeTextFrame(w io.Writer, p []byte) error {
	return ctrl.WriteTextFrame(w, p)
}

type (
	fetchRequest = subfetch.Request
	fetchResult  = subfetch.Result
)

func fetch(req fetchRequest) fetchResult { return eng.Fetch(req) }
func prefetch(path string) (int, error)  { return eng.Prefetch(path) }

func setCommandDispatcher(fn ctrl.CommandDispatcher) { ctrl.SetCommandDispatcher(fn) }
func replyCommand(id int64, status int, body []byte) { ctrl.ReplyCommand(id, status, body) }
func emitRaw(data []byte)                            { ctrl.EmitRaw(data) }
