package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"time"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
)

type tailscaleLoginResponse struct {
	BootID         string `json:"bootId"`
	ConfigRevision uint64 `json:"configRevision"`
	ID             string `json:"id"`
	State          string `json:"state"`
	AuthURL        string `json:"authUrl,omitempty"`
}

type tailscaleLoginAdapter interface {
	ArkClashTailscaleLogin(context.Context) (string, string, error)
}

func validTailscaleAuthURL(raw string) bool {
	if len(raw) == 0 || len(raw) > 8192 || strings.ContainsAny(raw, "\\ \t\r\n") {
		return false
	}
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "https" || u.Scheme == "http") && u.Hostname() != "" && u.User == nil
}

func requestTailscaleLogin(ctx context.Context, req proxyDefinitionRequest) (tailscaleLoginResponse, int, error) {
	var (
		proxy C.Proxy
		code  int
		err   error
	)
	_ = eng.withState(func(tx *stateTx) error {
		proxy, code, err = lookupProxyLocked(req)
		return nil
	})
	if err != nil {
		return tailscaleLoginResponse{}, code, err
	}
	target, ok := proxy.Adapter().(tailscaleLoginAdapter)
	if proxy.Type() != C.Tailscale || !ok {
		return tailscaleLoginResponse{}, http.StatusBadRequest, errors.New("tailscale_login_unavailable")
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	state, authURL, loginErr := target.ArkClashTailscaleLogin(ctx)
	var active C.Proxy
	_ = eng.withState(func(tx *stateTx) error {
		active, code, err = lookupProxyLocked(req)
		return nil
	})
	if err != nil {
		return tailscaleLoginResponse{}, code, err
	}
	if active != proxy {
		return tailscaleLoginResponse{}, http.StatusConflict, errors.New("proxy_stale_config")
	}
	if loginErr != nil {
		if !errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return tailscaleLoginResponse{}, http.StatusServiceUnavailable, errors.New("tailscale_login_failed")
		}
		state, authURL = "pending", ""
	}
	switch state {
	case "running", "key-configured", "needs-approval", "pending":
		authURL = ""
	case "authorize":
		if !validTailscaleAuthURL(authURL) {
			return tailscaleLoginResponse{}, http.StatusServiceUnavailable, errors.New("tailscale_login_failed")
		}
	default:
		return tailscaleLoginResponse{}, http.StatusServiceUnavailable, errors.New("tailscale_login_failed")
	}
	return tailscaleLoginResponse{BootID: req.BootID, ConfigRevision: req.ConfigRevision, ID: req.ID,
		State: state, AuthURL: authURL}, http.StatusOK, nil
}

func postTailscaleLogin(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	var req proxyDefinitionRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 32<<10)).Decode(&req); err != nil {
		writeError(w, r, http.StatusBadRequest, errors.New("proxy_invalid_request"))
		return
	}
	result, code, err := requestTailscaleLogin(r.Context(), req)
	if err != nil {
		writeError(w, r, code, err)
		return
	}
	render.JSON(w, r, result)
}
