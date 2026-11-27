package engine

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"time"

	"github.com/metacubex/http"
	C "github.com/metacubex/mihomo/constant"
)

type TailscaleLoginResponse struct {
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

func (e *Engine) RequestTailscaleLogin(ctx context.Context, req ProxyDefinitionRequest) (TailscaleLoginResponse, int, error) {
	var (
		proxy C.Proxy
		code  int
		err   error
	)
	_ = e.withState(func(tx *stateTx) error {
		proxy, code, err = e.lookupProxyLocked(req)
		return nil
	})
	if err != nil {
		return TailscaleLoginResponse{}, code, err
	}
	target, ok := proxy.Adapter().(tailscaleLoginAdapter)
	if proxy.Type() != C.Tailscale || !ok {
		return TailscaleLoginResponse{}, http.StatusBadRequest, errors.New("tailscale_login_unavailable")
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	state, authURL, loginErr := target.ArkClashTailscaleLogin(ctx)
	var active C.Proxy
	_ = e.withState(func(tx *stateTx) error {
		active, code, err = e.lookupProxyLocked(req)
		return nil
	})
	if err != nil {
		return TailscaleLoginResponse{}, code, err
	}
	if active != proxy {
		return TailscaleLoginResponse{}, http.StatusConflict, errors.New("proxy_stale_config")
	}
	if loginErr != nil {
		if !errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return TailscaleLoginResponse{}, http.StatusServiceUnavailable, errors.New("tailscale_login_failed")
		}
		state, authURL = "pending", ""
	}
	switch state {
	case "running", "key-configured", "needs-approval", "pending":
		authURL = ""
	case "authorize":
		if !validTailscaleAuthURL(authURL) {
			return TailscaleLoginResponse{}, http.StatusServiceUnavailable, errors.New("tailscale_login_failed")
		}
	default:
		return TailscaleLoginResponse{}, http.StatusServiceUnavailable, errors.New("tailscale_login_failed")
	}
	return TailscaleLoginResponse{BootID: req.BootID, ConfigRevision: req.ConfigRevision, ID: req.ID,
		State: state, AuthURL: authURL}, http.StatusOK, nil
}
